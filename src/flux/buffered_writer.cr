require "log"
require "tasker"

require "./client"
require "./point"

class Flux::BufferedWriter
  Log = ::Log.for(self)

  private getter client : Flux::Client

  private getter bucket : String

  private getter buffer : Channel(Point)

  private getter writer : Channel(Array(Point))

  private getter batch_size : Int32

  private getter flush_delay : Time::Span

  private getter schedule = Tasker.instance

  private getter buffer_mutex = Mutex.new

  private getter write_task_mutex = Mutex.new(protection: Mutex::Protection::Reentrant)

  private getter queue_length = 0

  private getter write_task : Tasker::Task?

  # Creates a new buffered writer for storing points in *bucket* via *client*.
  #
  # Writes to the underlying client are deferred until *batch_size* points are
  # cached or no additional write call is made for *flush_delay*.
  def initialize(@client, @bucket, @batch_size = 5000, @flush_delay = 1.seconds)
    @buffer = Channel(Point).new(batch_size * 2)
    @writer = Channel(Array(Point)).new
    spawn do
      loop do
        points = writer.receive
        write points
      end
    end
  end

  # Enqueue a *point* for writing.
  def enqueue(point : Point) : Nil
    buffer.send point
    buffer_mutex.synchronize { @queue_length += 1 }
    flush
  end

  # Flush any fully buffered writes, or schedules a task for partials.
  def flush : Nil
    while queue_length >= batch_size
      write_task_mutex.synchronize do
        @write_task.try &.cancel
        @write_task = nil
      end
      dequeue batch_size
    end

    if queue_length > 0
      write_task_mutex.synchronize do
        @write_task ||= schedule.in(flush_delay) do
          write_task_mutex.synchronize { @write_task = nil }
          dequeue queue_length
        end
      end
    end
  end

  # Dequeue up to *count* points.
  private def dequeue(count : Int)
    read = 0
    points = Array(Point).build(count) do |arr|
      while read < count && (point = buffer.receive?)
        arr[read] = point
        read += 1
      end
      read
    end
    buffer_mutex.synchronize { @queue_length -= read }
    writer.send points
    points
  end

  # Perform blocking write of a set of *points* via the wrapped client.
  #
  # Error will be retried as appropriate.
  private def write(points : Enumerable(Point), retries = 3)
    client.write bucket, points
    Log.info { "#{points.size} points written" }
  rescue ex : TooManyRequests
    Log.warn(exception: ex) { ex.message }
    sleep ex.retry_after
    write points
  rescue ex : ServerError
    retries -= 1
    if retries > 0
      Log.warn { "#{ex.message}, retrying write request" }
      write points, retries
    else
      Log.error { "#{ex.message}, retries exhausted - dropping write request" }
    end
  rescue ex : Error
    Log.error { "#{ex.message}, dropping write request" }
  end
end
