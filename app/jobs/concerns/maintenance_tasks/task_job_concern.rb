# frozen_string_literal: true

module MaintenanceTasks
  # Concern that holds the behaviour of the job that runs the tasks. It is
  # included in {TaskJob} and if MaintenanceTasks.job is overridden, it must be
  # included in the job.
  module TaskJobConcern
    extend ActiveSupport::Concern
    include JobIteration::Iteration

    included do
      before_perform(:before_perform)

      on_start(:on_start)
      on_complete(:on_complete)
      on_shutdown(:on_shutdown)

      after_perform(:after_perform)

      rescue_from StandardError, with: :on_error
    end

    class_methods do
      # Overrides ActiveJob::Exceptions.retry_on to declare it unsupported.
      # The use of rescue_from prevents retry_on from being usable.
      def retry_on(*, **)
        raise NotImplementedError, "retry_on is not supported"
      end
    end

    private

    def build_enumerator(_run, cursor:)
      cursor ||= @run.cursor
      collection = @task.collection
      @enumerator = nil

      collection_enum = case collection
      when ActiveRecord::Relation
        enumerator_builder.active_record_on_records(collection, cursor: cursor)
      when ActiveRecord::Batches::BatchEnumerator
        if collection.start || collection.finish
          raise ArgumentError, <<~MSG.squish
            #{@task.class.name}#collection cannot support
            a batch enumerator with the "start" or "finish" options.
          MSG
        end
        # For now, only support automatic count based on the enumerator for
        # batches
        @enumerator = enumerator_builder.active_record_on_batch_relations(
          collection.relation,
          cursor: cursor,
          batch_size: collection.batch_size,
        )
      when Array
        enumerator_builder.build_array_enumerator(collection, cursor: cursor)
      when CSV
        JobIteration::CsvEnumerator.new(collection).rows(cursor: cursor)
      else
        raise ArgumentError, <<~MSG.squish
          #{@task.class.name}#collection must be either an
          Active Record Relation, ActiveRecord::Batches::BatchEnumerator,
          Array, or CSV.
        MSG
      end

      @task.throttle_conditions.reduce(collection_enum) do |enum, condition|
        enumerator_builder.build_throttle_enumerator(enum, **condition)
      end
    end

    # Performs task iteration logic for the current input returned by the
    # enumerator.
    #
    # @param input [Object] the current element from the enumerator.
    # @param _run [Run] the current Run, passed as an argument by Job Iteration.
    def each_iteration(input, _run)
      throw(:abort, :skip_complete_callbacks) if @run.stopping?
      task_iteration(input)
      @ticker.tick
      @run.reload_status
    end

    def task_iteration(input)
      @task.process(input)
    rescue => error
      @errored_element = input
      raise error
    end

    def before_perform
      @run = arguments.first
      @task = @run.task
      if @task.has_csv_content?
        @task.csv_content = @run.csv_file.download
      end

      @run.running

      @ticker = Ticker.new(MaintenanceTasks.ticker_delay) do |ticks, duration|
        @run.persist_progress(ticks, duration)
      end
    end

    def on_start
      count = @task.count
      count = @enumerator&.size if count == :no_count
      @run.update!(started_at: Time.now, tick_total: count)
      @task.run_callbacks(:start)
    end

    def on_complete
      @run.status = :succeeded
      @run.ended_at = Time.now
      @task.run_callbacks(:complete)
    end

    def on_shutdown
      if @run.cancelling?
        @run.status = :cancelled
        @task.run_callbacks(:cancel)
        @run.ended_at = Time.now
      elsif @run.pausing?
        @run.status = :paused
        @task.run_callbacks(:pause)
      else
        @run.status = :interrupted
        @task.run_callbacks(:interrupt)
      end

      @run.cursor = cursor_position
      @ticker.persist
    end

    # We are reopening a private part of Job Iteration's API here, so we should
    # ensure the method is still defined upstream. This way, in the case where
    # the method changes upstream, we catch it at load time instead of at
    # runtime while calling `super`.
    unless JobIteration::Iteration
        .private_method_defined?(:reenqueue_iteration_job)
      error_message = <<~HEREDOC
        JobIteration::Iteration#reenqueue_iteration_job is expected to be
        defined. Upgrading the maintenance_tasks gem should solve this problem.
      HEREDOC
      raise error_message
    end
    def reenqueue_iteration_job(should_ignore: true)
      super() unless should_ignore
      @reenqueue_iteration_job = true
    end

    def after_perform
      @run.save!
      if defined?(@reenqueue_iteration_job) && @reenqueue_iteration_job
        reenqueue_iteration_job(should_ignore: false)
      end
    end

    def on_error(error)
      @ticker.persist if defined?(@ticker)

      if defined?(@run)
        @run.persist_error(error)

        task_context = {
          task_name: @run.task_name,
          started_at: @run.started_at,
          ended_at: @run.ended_at,
        }
      else
        task_context = {}
      end
      errored_element = @errored_element if defined?(@errored_element)
      run_error_callback
    ensure
      MaintenanceTasks.error_handler.call(error, task_context, errored_element)
    end

    def run_error_callback
      @task.run_callbacks(:error) if defined?(@task)
    rescue
      nil
    end
  end
end
