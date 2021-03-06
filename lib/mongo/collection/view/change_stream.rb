# Copyright (C) 2017-2019 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'mongo/collection/view/change_stream/retryable'

module Mongo
  class Collection
    class View

      # Provides behavior around a `$changeStream` pipeline stage in the
      # aggregation framework. Specifying this stage allows users to request
      # that notifications are sent for all changes to a particular collection
      # or database.
      #
      # @note Only available in server versions 3.6 and higher.
      # @note ChangeStreams do not work properly with JRuby because of the
      #  issue documented here: https://github.com/jruby/jruby/issues/4212.
      #  Namely, JRuby eagerly evaluates #next on an Enumerator in a background
      #  green thread, therefore calling #next on the change stream will cause
      #  getMores to be called in a loop in the background.
      #
      #
      # @since 2.5.0
      class ChangeStream < Aggregation
        include Retryable

        # @return [ String ] The fullDocument option default value.
        #
        # @since 2.5.0
        FULL_DOCUMENT_DEFAULT = 'default'.freeze

        # @return [ Symbol ] Used to indicate that the change stream should listen for changes on
        #   the entire database rather than just the collection.
        #
        # @since 2.6.0
        DATABASE = :database

        # @return [ Symbol ] Used to indicate that the change stream should listen for changes on
        #   the entire cluster rather than just the collection.
        #
        # @since 2.6.0
        CLUSTER = :cluster

        # @return [ BSON::Document ] The change stream options.
        #
        # @since 2.5.0
        attr_reader :options

        # Initialize the change stream for the provided collection view, pipeline
        # and options.
        #
        # @example Create the new change stream view.
        #   ChangeStream.new(view, pipeline, options)
        #
        # @param [ Collection::View ] view The collection view.
        # @param [ Array<Hash> ] pipeline The pipeline of operators to filter the change notifications.
        # @param [ Hash ] options The change stream options.
        #
        # @option options [ String ] :full_document Allowed values: 'default', 'updateLookup'. Defaults to 'default'.
        #   When set to 'updateLookup', the change notification for partial updates will include both a delta
        #   describing the changes to the document, as well as a copy of the entire document that was changed
        #   from some time after the change occurred.
        # @option options [ BSON::Document, Hash ] :resume_after Specifies the logical starting point for the
        #   new change stream.
        # @option options [ Integer ] :max_await_time_ms The maximum amount of time for the server to wait
        #   on new documents to satisfy a change stream query.
        # @option options [ Integer ] :batch_size The number of documents to return per batch.
        # @option options [ BSON::Document, Hash ] :collation The collation to use.
        # @option options [ BSON::Timestamp ] :start_at_operation_time Only
        #   return changes that occurred at or after the specified timestamp. Any
        #   command run against the server will return a cluster time that can
        #   be used here. Only recognized by server versions 4.0+.
        #
        # @since 2.5.0
        def initialize(view, pipeline, changes_for, options = {})
          @view = view
          @changes_for = changes_for
          @change_stream_filters = pipeline && pipeline.dup
          @options = options && options.dup.freeze
          @resume_token = @options[:resume_after]
          create_cursor!

          # We send different parameters when we resume a change stream
          # compared to when we send the first query
          @resuming = true
        end

        # Iterate through documents returned by the change stream.
        #
        # This method retries once per error on resumable errors
        # (two consecutive errors result in the second error being raised,
        # an error which is recovered from resets the error count to zero).
        #
        # @example Iterate through the stream of documents.
        #   stream.each do |document|
        #     p document
        #   end
        #
        # @return [ Enumerator ] The enumerator.
        #
        # @since 2.5.0
        #
        # @yieldparam [ BSON::Document ] Each change stream document.
        def each
          raise StopIteration.new if closed?
          retried = false
          begin
            @cursor.each do |doc|
              cache_resume_token(doc)
              yield doc
            end if block_given?
            @cursor.to_enum
          rescue Mongo::Error => e
            if retried || !e.change_stream_resumable?
              raise
            end

            retried = true
            # Rerun initial aggregation.
            # Any errors here will stop iteration and break out of this
            # method
            close
            create_cursor!
            retry
          end
        end

        # Return one document from the change stream, if one is available.
        #
        # Retries once on a resumable error.
        #
        # Raises StopIteration if the change stream is closed.
        #
        # This method will wait up to max_await_time_ms milliseconds
        # for changes from the server, and if no changes are received
        # it will return nil.
        #
        # @note This method is experimental and subject to change.
        #
        # @return [ BSON::Document | nil ] A change stream document.
        # @api experimental
        # @since 2.6.0
        def try_next
          raise StopIteration.new if closed?
          retried = false

          begin
            doc = @cursor.try_next
          rescue Mongo::Error => e
            unless e.change_stream_resumable?
              raise
            end

            if retried
              # Rerun initial aggregation.
              # Any errors here will stop iteration and break out of this
              # method
              close
              create_cursor!
              retried = false
              doc = @cursor.try_next
            else
              # Attempt to retry a getMore once
              retried = true
              retry
            end
          end

          if doc
            cache_resume_token(doc)
          end
          doc
        end

        def to_enum
          enum = super
          enum.send(:instance_variable_set, '@obj', self)
          class << enum
            def try_next
              @obj.try_next
            end
          end
          enum
        end

        # Close the change stream.
        #
        # @example Close the change stream.
        #   stream.close
        #
        # @return [ nil ] nil.
        #
        # @since 2.5.0
        def close
          unless closed?
            begin; @cursor.send(:kill_cursors); rescue; end
            @cursor = nil
          end
        end

        # Is the change stream closed?
        #
        # @example Determine whether the change stream is closed.
        #   stream.closed?
        #
        # @return [ true, false ] If the change stream is closed.
        #
        # @since 2.5.0
        def closed?
          @cursor.nil?
        end

        # Get a formatted string for use in inspection.
        #
        # @example Inspect the change stream object.
        #   stream.inspect
        #
        # @return [ String ] The change stream inspection.
        #
        # @since 2.5.0
        def inspect
          "#<Mongo::Collection::View:ChangeStream:0x#{object_id} filters=#{@change_stream_filters} " +
            "options=#{@options} resume_token=#{@resume_token}>"
        end

        private

        def for_cluster?
          @changes_for == CLUSTER
        end

        def for_database?
          @changes_for == DATABASE
        end

        def for_collection?
          !for_cluster? && !for_database?
        end

        def cache_resume_token(doc)
          # Always record both resume token and operation time,
          # in case we get an older or newer server during rolling
          # upgrades/downgrades
          unless @resume_token = (doc[:_id] && doc[:_id].dup)
            raise Error::MissingResumeToken
          end
        end

        def create_cursor!
          # clear the cache because we may get a newer or an older server
          # (rolling upgrades)
          @start_at_operation_time_supported = nil

          session = client.send(:get_session, @options)
          server = server_selector.select_server(cluster)
          result = send_initial_query(server, session)
          if doc = result.replies.first && result.replies.first.documents.first
            @start_at_operation_time = doc['operationTime']
          else
            # The above may set @start_at_operation_time to nil
            # if it was not in the document for some reason,
            # for consistency set it to nil here as well
            @start_at_operation_time = nil
          end
          @cursor = Cursor.new(view, result, server, disable_retry: true, session: session)
        end

        def pipeline
          [{ '$changeStream' => change_doc }] + @change_stream_filters
        end

        def aggregate_spec(session)
          super(session).tap do |spec|
            spec[:selector][:aggregate] = 1 unless for_collection?
          end
        end

        def change_doc
          { fullDocument: ( @options[:full_document] || FULL_DOCUMENT_DEFAULT ) }.tap do |doc|
            if resuming?
              # We have a resume token once we retrieved any documents.
              # However, if the first getMore fails and the user didn't pass
              # a resume token we won't have a resume token to use.
              # Use start_at_operation time in this case
              if @resume_token
                # Spec says we need to remove startAtOperationTime if
                # one was passed in by user, thus we won't forward it
              elsif start_at_operation_time_supported? && @start_at_operation_time
                # It is crucial to check @start_at_operation_time_supported
                # here - we may have switched to an older server that
                # does not support operation times and therefore shouldn't
                # try to send one to it!
                #
                # @start_at_operation_time is already a BSON::Timestamp
                doc[:startAtOperationTime] = @start_at_operation_time
              else
                # Can't resume if we don't have either
                raise Mongo::Error::MissingResumeToken
              end
            else
              if options[:start_at_operation_time]
                doc[:startAtOperationTime] = time_to_bson_timestamp(
                  options[:start_at_operation_time])
              end
            end
            doc[:resumeAfter] = @resume_token if @resume_token
            doc[:allChangesForCluster] = true if for_cluster?
          end
        end

        def send_initial_query(server, session)
          initial_query_op(session).execute(server)
        end

        def time_to_bson_timestamp(time)
          if time.is_a?(Time)
            seconds = time.to_f
            BSON::Timestamp.new(seconds.to_i, ((seconds - seconds.to_i) * 1000000).to_i)
          elsif time.is_a?(BSON::Timestamp)
            time
          else
            raise ArgumentError, 'Time must be a Time or a BSON::Timestamp instance'
          end
        end

        def resuming?
          !!@resuming
        end

        def start_at_operation_time_supported?
          if @start_at_operation_time_supported.nil?
            server = server_selector.select_server(cluster)
            @start_at_operation_time_supported = server.description.max_wire_version >= 7
          end
          @start_at_operation_time_supported
        end
      end
    end
  end
end
