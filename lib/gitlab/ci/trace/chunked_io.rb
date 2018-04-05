##
# This class is compatible with IO class (https://ruby-doc.org/core-2.3.1/IO.html)
# source: https://gitlab.com/snippets/1685610
module Gitlab
  module Ci
    class Trace
      class ChunkedIO
        CHUNK_SIZE = ::Ci::JobTraceChunk::CHUNK_SIZE

        FailedToGetChunkError = Class.new(StandardError)

        attr_reader :job
        attr_reader :tell, :size
        attr_reader :chunk, :chunk_range

        alias_method :pos, :tell

        def initialize(job, &block)
          @job = job
          @chunks_cache = []
          @tell = 0
          @size = job_chunks.last.try(&:end_offset).to_i
          yield self if block_given?
        end

        def close
          # no-op
        end

        def binmode
          # no-op
        end

        def binmode?
          true
        end

        def seek(pos, where = IO::SEEK_SET)
          new_pos =
            case where
            when IO::SEEK_END
              size + pos
            when IO::SEEK_SET
              pos
            when IO::SEEK_CUR
              tell + pos
            else
              -1
            end

          raise 'new position is outside of file' if new_pos < 0 || new_pos > size

          @tell = new_pos
        end

        def eof?
          tell == size
        end

        def each_line
          until eof?
            line = readline
            break if line.nil?

            yield(line)
          end
        end

        def read(length = nil, outbuf = "")
          out = ""

          length ||= size - tell

          until length <= 0 || eof?
            data = chunk_slice_from_offset
            break if data.empty?

            chunk_bytes = [CHUNK_SIZE - chunk_offset, length].min
            chunk_data = data.byteslice(0, chunk_bytes)

            out << chunk_data
            @tell += chunk_data.bytesize
            length -= chunk_data.bytesize
          end

          # If outbuf is passed, we put the output into the buffer. This supports IO.copy_stream functionality
          if outbuf
            outbuf.slice!(0, outbuf.bytesize)
            outbuf << out
          end

          out
        end

        def readline
          out = ""

          until eof?
            data = chunk_slice_from_offset
            new_line = data.index("\n")

            if !new_line.nil?
              out << data[0..new_line]
              @tell += new_line + 1
              break
            else
              out << data
              @tell += data.bytesize
            end
          end

          out
        end

        def write(data)
          raise 'Could not write empty data' unless data.present?

          start_pos = tell
          data = data.force_encoding(Encoding::BINARY)

          while tell < start_pos + data.bytesize
            # get slice from current offset till the end where it falls into chunk
            chunk_bytes = CHUNK_SIZE - chunk_offset
            chunk_data = data.byteslice(tell - start_pos, chunk_bytes)

            # append data to chunk, overwriting from that point
            ensure_chunk.append(chunk_data, chunk_offset)

            # move offsets within buffer
            @tell += chunk_data.bytesize
            @size = [size, tell].max
          end

          tell - start_pos
        ensure
          invalidate_chunk_cache
        end

        def truncate(offset)
          raise 'Outside of file' if offset > size

          @tell = offset
          @size = offset

          # remove all next chunks
          job_chunks.where('chunk_index > ?', chunk_index).destroy_all

          # truncate current chunk
          current_chunk.truncate(chunk_offset) if chunk_offset != 0
        ensure
          invalidate_chunk_cache
        end

        def flush
          # no-op
        end

        def present?
          true
        end

        def destroy!
          job_chunks.destroy_all
          @tell = @size = 0
        ensure
          invalidate_chunk_cache
        end

        private

        ##
        # The below methods are not implemented in IO class
        #
        def in_range?
          @chunk_range&.include?(tell)
        end

        def chunk_slice_from_offset
          unless in_range?
            current_chunk.tap do |chunk|
              raise FailedToGetChunkError unless chunk

              @chunk = chunk.data.force_encoding(Encoding::BINARY)
              @chunk_range = chunk.range
            end
          end

          @chunk[chunk_offset..CHUNK_SIZE]
        end

        def chunk_offset
          tell % CHUNK_SIZE
        end

        def chunk_index
          tell / CHUNK_SIZE
        end

        def chunk_start
          chunk_index * CHUNK_SIZE
        end

        def chunk_end
          [chunk_start + CHUNK_SIZE, size].min
        end

        def invalidate_chunk_cache
          @chunks_cache = []
        end

        def current_chunk
          @chunks_cache[chunk_index] ||= job_chunks.find_by(chunk_index: chunk_index)
        end

        def build_chunk
          @chunks_cache[chunk_index] = ::Ci::JobTraceChunk.new(job: job, chunk_index: chunk_index)
        end

        def ensure_chunk
          current_chunk || build_chunk
        end

        def job_chunks
          ::Ci::JobTraceChunk.where(job: job)
        end
      end
    end
  end
end
