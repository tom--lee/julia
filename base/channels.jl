# This file is a part of Julia. License is MIT: http://julialang.org/license

abstract ChannelData{T}

type ChannelDataSingle{T} <: ChannelData{T}
    full::Bool          # Need a separate flag here to handle the case where "nothing" is a valid value in "data"
    data::Nullable{T}
end

type ChannelDataMultiple{T} <: ChannelData{T}
    data::Array{T,1}
    szp1::Int               # current channel size plus one
    sz_max::Int             # maximum size of channel
    take_pos::Int           # read position
    put_pos::Int            # write position
end

type ChannelAddr
    pid::Int
    cid::Int
end

abstract AbstractChannel{T}

type Channel{T, Many} <: AbstractChannel{T}
    cid::Int
    store::ChannelData{T}
    cond_take::Condition    # waiting for data to become available
    cond_put::Condition     # waiting for a writeable slot

    function Channel(Ty::Type, szp1::Int, sz_max::Int)
        if sz_max==1
            store = ChannelDataSingle{Ty}(false, Nullable{T}())
        else
            store = ChannelDataMultiple{Ty}(Array(Ty, szp1), szp1, sz_max, 1, 1)
        end
        new(get_next_channel_id(), store, Condition(), Condition())
    end
end

let next_channel_id=1
    global get_next_channel_id
    function get_next_channel_id()
        cid = next_channel_id
        next_channel_id = next_channel_id+1
        return cid
    end
end

Channel() = Channel(1)
Channel(sz::Int) = Channel(Any, sz)
Channel(T::Type) = Channel(T, 1)
function Channel(T::Type, sz::Int)
    sz_max = sz == typemax(Int) ? typemax(Int) - 1 : sz
    csz = sz > 32 ? 32 : sz
    if sz_max == 1
        Channel{T, false}(T, csz+1, sz_max)
    else
        Channel{T, true}(T, csz+1, sz_max)
    end
end

map_all_channels = Dict{Int, AbstractChannel}()
register_channel(c::Channel) = (map_all_channels[c.cid] = c; ChannelAddr(myid(), c.cid))
create_and_register_channel(T::Type, sz::Int) = register_channel(Channel(T, sz))

channel_at(pid::Int=myid(), T::Type=Any, sz::Int=1) = remotecall_fetch(pid, create_and_register_channel, T, sz)

close_channel(cid::Int) = (delete!(map_all_channels, cid); nothing)
close(addr::ChannelAddr) = remotecall_fetch(addr.pid, close_channel, addr.cid)

# TODO Implement
# put!(addr::ChannelAddr, v)
# take!(addr::ChannelAddr)
# fetch(addr::ChannelAddr)
# isready(addr::ChannelAddr)
# wait(addr::ChannelAddr)


function put!{T}(c::Channel{T, true}, v::T)
    store = c.store
    d = store.take_pos - store.put_pos
    if (d == 1) || (d == -(store.szp1-1))
        # grow the channel if possible
        if (store.szp1 - 1) < store.sz_max
            if ((store.szp1-1) * 2) > store.sz_max
                store.szp1 = store.sz_max + 1
            else
                store.szp1 = ((store.szp1-1) * 2) + 1
            end
            newdata = Array(eltype(c), store.szp1)
            if store.put_pos > store.take_pos
                copy!(newdata, 1, store.data, store.take_pos, (store.put_pos - store.take_pos))
                store.put_pos = store.put_pos - store.take_pos + 1
            else
                len_first_part = length(store.data) - store.take_pos + 1
                copy!(newdata, 1, store.data, store.take_pos, len_first_part)
                copy!(newdata, len_first_part+1, store.data, 1, store.put_pos-1)
                store.put_pos = len_first_part + store.put_pos
            end
            store.take_pos = 1
            store.data = newdata
        else
            wait(c.cond_put)
        end
    end

    store.data[store.put_pos] = v
    store.put_pos = (store.put_pos == store.szp1 ? 1 : store.put_pos + 1)
    notify(c.cond_take, nothing, true, false)  # notify all, since some of the waiters may be on a "fetch" call.
    v
end

function put!{T}(c::Channel{T, false}, v::T)
    if c.store.full
        wait(c.cond_put)
    end
    c.store.data = v
    c.store.full = true
    notify(c.cond_take, nothing, true, false)
    v
end

function fetch(c::Channel)
    while !isready(c)
        wait(c.cond_take)
    end
    fetch(c.store)
end

fetch(store::ChannelDataSingle) = get(store.data)
fetch(store::ChannelDataMultiple) = store.data[store.take_pos]

function take!(c::Channel)
    while !isready(c)
        wait(c.cond_take)
    end
    v = take!(c.store)
    notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
    v
end

take!(store::ChannelDataSingle) = (v=get(store.data, nothing); store.data=nothing; store.full=false; v)
function take!(store::ChannelDataMultiple)
    v = store.data[store.take_pos]
    store.take_pos = (store.take_pos == store.szp1 ? 1 : store.take_pos + 1)
    v
end

isready{T}(c::Channel{T, false}) = c.store.full
isready{T}(c::Channel{T, true}) = (c.store.take_pos == c.store.put_pos ? false : true)

function wait(c::Channel)
    while !isready(c)
        wait(c.cond_take)
    end
    nothing
end

function notify_error(c::Channel, err)
    notify_error(c.cond_take, err)
    notify_error(c.cond_put, err)
end

eltype{T}(c::Channel{T}) = T

function length{T}(c::Channel{T, true})
    store=c.store
    if store.put_pos >= store.take_pos
        return store.put_pos - store.take_pos
    else
        return store.szp1 - store.take_pos + store.put_pos
    end
end

length{T}(c::Channel{T, false}) = c.store.full ? 1 : 0

size{T}(c::Channel{T, false}) = 1
size{T}(c::Channel{T, true}) = c.store.sz_max

show(io::IO, c::Channel) = print(io, "$(typeof(c))(id: $(c.cid), size: $(size(c)), num_elements: $(length(c)))")
