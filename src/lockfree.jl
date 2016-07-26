"""
This type is a container type that we hold a reference to in order to make sure
that the garbage collector doesn't free up the memory that backs up our ring
buffers.
"""
type LockFreeRingBufferData{T}
    buf::Vector{T}
    nread::UInt
    nwritten::UInt
end

# keep all our references here
const ringbufs = Set{LockFreeRingBufferData}()

"""
A LockFreeRingBuffer implements a single-producer single-consumer lock-free ring
buffer. It doesn't provide any of the queuing behavior.

This also provides a mechanism to read and write from a ring buffer without
interacting with Julia's memory management, which makes this type useful for
cases where data is produced and/or consumed from a separate thread's context,
such as when interfacing with an audio library.

Note that this is an immutable object with pointers to heap-allocated data.
This way we can pass it around as a stack-allocated object without hitting
the garbage collector infrastructure.
"""
immutable LockFreeRingBuffer{T}
    size::UInt
    buf::Ptr{T}
    nread::Ptr{UInt}
    nwritten::Ptr{UInt}
    container::Ptr{LockFreeRingBufferData{T}}
    waiters::Condition
end

function LockFreeRingBuffer(T, size)
    size = nextpow2(size)
    container = LockFreeRingBufferData(Array(T, size), UInt(0), UInt(0))
    push!(ringbufs, container)
    rootaddr = pointer_from_objref(container)
    bufptr = Ptr{T}(pointer(container.buf))
    nreadptr = Ptr{UInt}(rootaddr + fieldnameoffset(LockFreeRingBufferData{T}, :nread))
    nwrittenptr = Ptr{UInt}(rootaddr + fieldnameoffset(LockFreeRingBufferData{T}, :nwritten))
    containerptr = Ptr{LockFreeRingBufferData{T}}(rootaddr)

    LockFreeRingBuffer(UInt(size), bufptr, nreadptr, nwrittenptr, containerptr, Condition())
end


function readable(buf::LockFreeRingBuffer)
    nread = unsafe_load(buf.nread)
    nwritten = unsafe_load(buf.nwritten)

    nwritten - nread
end

writable(buf::LockFreeRingBuffer) = buf.size - readable(buf)

function write{T}(buf::LockFreeRingBuffer{T}, data::Ptr{T}, n)
    n = min(n, writable(buf))
    writepos = unsafe_load(buf.nwritten) + 1
    sizemask = buf.size - 1
    for i in 1:n
        unsafe_store!(buf.buf, unsafe_load(data, i), (writepos + i) & sizemask)
    end

    unsafe_store!(buf.nwritten, unsafe_load(buf.nwritten) + n)
    # we can only notify without allocating in 0.5 and above
    @static if VERSION >= v"0.5-"
        notify(buf.waiters)
    end

    n
end

write{T}(buf::LockFreeRingBuffer{T}, data::Vector{T}, n=length(data)) = write(buf, pointer(data), UInt(n))

function read!{T}(buf::LockFreeRingBuffer{T}, data::Ptr{T}, n)
    n = min(n, readable(buf))
    readpos = unsafe_load(buf.nread) + 1
    sizemask = buf.size - 1
    for i in 1:n
        unsafe_store!(data, unsafe_load(buf.buf, (readpos + i) & sizemask), i)
    end

    unsafe_store!(buf.nread, unsafe_load(buf.nread) + n)
    # we can only notify without allocating in 0.5 and above
    @static if VERSION >= v"0.5-"
        notify(buf.waiters)
    end

    n
end

read!{T}(buf::LockFreeRingBuffer{T}, data::Vector{T}, n=length(data)) = read!(buf, pointer(data), UInt(n))

# this just removes the container from our ringbufs list, so the GC can do its
# thing. After this all the pointers should be considered invalid
function Base.close(buf::LockFreeRingBuffer)
    pop!(ringbufs, unsafe_pointer_to_objref(buf.container))
end

# prior to 0.5 it's impossible to notify a condition without allocating, so
# we can't wake up waiters. In that case we poll and wake up the waiter when
# anything changes. The poll time (5ms) is set with the intended use-case of
# filling an audio buffer that needs to be responsive
@static if VERSION >= v"0.5-"
    wait(buf::LockFreeRingBuffer) = wait(buf.waiters)
else
    function wait(buf::LockFreeRingBuffer)
        nread = unsafe_load(buf.nread)
        nwritten = unsafe_load(buf.nwritten)
        while unsafe_load(buf.nread) == nread && unsafe_load(buf.nwritten) == nwritten
            sleep(0.005)
        end
    end
end

"Gives the memory offset of the given field, given as a symbol"
fieldnameoffset(T, fname) = fieldoffset(T, findfirst(fieldnames(T), fname))