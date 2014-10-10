//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Despiker backend.
module despiker.backend;


import std.algorithm;
import std.array;
import std.stdio;

import tharsis.prof;

import despiker.profdatasource: ProfileDataChunk;


/** Maximum threads supported by Despiker at the moment.
 *
 * Increase when 1024 is too few, in 2025 or so.
 */
enum maxThreads = 1024;


/** Information about a 'frame zone' - stored in a random access array.
 *
 * All frames are stored in a random-access array for quick access, so this should be
 * as small as possible to avoid wasting memory.
 */
struct FrameInfo
{
    // Slice extents to get a slice of all events in the frame from ChunkyEventList.
    ChunkyEventList.SliceExtents extents;
    // Start time of the frame in hnsecs.
    ulong startTime;
    // Duration of the frame in hnsecs.
    ulong duration;

    // End time of the frame in hnsecs.
    ulong endTime() @safe pure nothrow const @nogc
    {
        return startTime + duration;
    }
}

/** Despiker backend.
 *
 * Handles storage of, processing of and access to profile data.
 */
final class Backend
{
public:
    /// Function that determines if a zone represents an entire frame.
    alias FrameFilter = bool delegate(ZoneData zone) @safe nothrow @nogc;

private:
    /// Default number of chunk structs (not the actual chunk data) to preallocate per thread.
    enum defaultChunkBufferSize = 60 * 3600;

    /// Profiling state kept for each profiled thread.
    struct ThreadState
    {
        /// 'chunk buffer' used by eventList to store chunk structs (not the actual chunk data)
        ChunkyEventList.Chunk[] chunkBuffer;
        /// Stores profiling data for this thread and provides API to read profiling events.
        ChunkyEventList eventList;
        /// Generates zones from events in eventList on-the-fly as new chunks are added.
        ChunkyZoneGenerator zoneGenerator;
        /** Stores information about frame zones (as determined by Backend.frameFilter_).
         *
         * Used to regenerate all events in a frame.
         */
        FrameInfo[] frames;
    }

    /// Thread state for all profiled thread.
    ThreadState[] threads_;

    /// Function that determines if a zone represents an entire frame.
    FrameFilter frameFilter_;

public:
    /** Construct Backend.
     *
     * Params:
     *
     * filter = Function to decide if a zone represents an entire frame.
     */
    this(FrameFilter frameFilter) @safe pure nothrow @nogc
    {
        frameFilter_ = frameFilter;
    }

    /** Add a chunk of profiling data.
     *
     * Thread index of the chunk must be lower than maxThreads.
     *
     * Whichever thread the chunk belongs to, its first event must have time at least
     * equal to the last event in the last chunk from that thread. (This can be achieved
     * by prefixing the chunk with a checkpoint event that stores absolute time - which
     * of course must be at least as late as any event in the previous chunk).
     */
    void addChunk(ProfileDataChunk chunk) @system nothrow
    {
        const tid = chunk.threadId;
        assert(tid <= maxThreads, "No more than 1024 threads are supported");

        // If we were unaware of this thread till now, add thread state for it.
        while(tid >= threads_.length)
        {
            threads_.assumeSafeAppend();
            threads_ ~= ThreadState.init;
            with(threads_.back)
            {
                chunkBuffer   = new ChunkyEventList.Chunk[defaultChunkBufferSize];
                eventList     = ChunkyEventList(chunkBuffer);
                // zoneGenerator = ChunkyZoneGenerator(eventList.generator);
                zoneGenerator = ChunkyZoneGenerator(eventList.generator);
            }
        }

        // Add the chunk.
        with(threads_[tid])
        {
            if(eventList.addChunk(chunk.data)) { return; }

            // If we failed to add chunk, it's time to reallocate.
            chunkBuffer = new ChunkyEventList.Chunk[chunkBuffer.length * 2];
            eventList.provideStorage(chunkBuffer);
            // TODO If needed, delete old chunkBuffer here  2014-10-02
            if(!eventList.addChunk(chunk.data))
            {
                assert(false, "Can't add chunk; probably start time lower than end time "
                              "of last chunk");
            }
        }
    }

    /// Get the number of profiled threads (so far).
    size_t threadCount() @safe pure nothrow const @nogc
    {
        return threads_.length;
    }

    /** Get access to frame info for all frames in specified profiled thread.
     *
     * Params:
     *
     * threadIdx = Index of the thread. Must be less than threadCount().
     */
    const(FrameInfo)[] frames(size_t threadIdx) @safe pure nothrow const @nogc
    {
        return threads_[threadIdx].frames;
    }

    /** Get read-only access to ChunkyEventList for specified profiled thread.
     *
     * Used e.g. to get event slices based on slice extents of a frame (read through
     * frames()).
     *
     * Params:
     *
     * threadIdx = Index of the thread. Must be less than threadCount().
     */
    ref const(ChunkyEventList) events(size_t threadIdx) @safe pure nothrow const @nogc
    {
        return threads_[threadIdx].eventList;
    }

    /** Update the Backend between Despiker frames.
     *
     * Must be called on each event loop update.
     */
    void update() @system nothrow
    {
        foreach(i, ref thread; threads_)
        {
            // Generate zones for any chunks that have been added since the last update().
            ChunkyZoneGenerator.GeneratedZoneData zone;
            while(thread.zoneGenerator.generate(zone)) if(frameFilter_(zone))
            {
                thread.frames.assumeSafeAppend();
                thread.frames ~= FrameInfo(zone.extents, zone.startTime, zone.duration);
            }
        }
    }
}
unittest
{
    writeln("Backend unittest");
    scope(success) { writeln("Backend unittest SUCCESS"); }
    scope(failure) { writeln("Backend unittest FAILURE"); }

    const frameCount = 16;

    bool filterFrames(ZoneData zone) @safe nothrow @nogc
    {
        return zone.info == "frame";
    }

    import std.typecons;
    auto profiler = scoped!Profiler(new ubyte[Profiler.maxEventBytes + 2048]);
    auto backend = new Backend(&filterFrames);

    size_t lastChunkEnd = 0;
    profiler.checkpointEvent();
    // std.typecons.scoped! stores the Profiler on the stack.
    // Simulate 16 'frames'
    foreach(frame; 0 .. frameCount)
    {
        Zone topLevel = Zone(profiler, "frame");

        // Simulate frame overhead. Replace this with your frame code.
        {
            Zone nested1 = Zone(profiler, "frameStart");
            foreach(i; 0 .. 1000) { continue; }
        }
        {
            Zone nested2 = Zone(profiler, "frameCore");
            foreach(i; 0 .. 10000) { continue; }
        }

        auto chunkData = profiler.profileData[lastChunkEnd .. $].idup;
        // Simulate adding chunks for multiple threads.
        backend.addChunk(ProfileDataChunk(0, chunkData));
        backend.addChunk(ProfileDataChunk(1, chunkData));
        backend.update();

        lastChunkEnd = profiler.profileData.length;
        profiler.checkpointEvent();
    }

    auto chunkData = profiler.profileData[lastChunkEnd .. $].idup;
    // Simulate adding chunks for multiple threads.
    backend.addChunk(ProfileDataChunk(0, chunkData));
    backend.addChunk(ProfileDataChunk(1, chunkData));
    backend.update();

    // Check that the time slices in 'frames' of each ThreadState match the zones filtered
    // as frames using filterFrames()
    assert(backend.threads_.length == 2);
    foreach(ref thread; backend.threads_)
    {
        auto frameZones = profiler.profileData.zoneRange.filter!filterFrames;
        foreach(frame; thread.frames)
        {
            const extents = frame.extents;
            const expectedFrameZone = frameZones.front;

            auto zonesInSlice = ZoneRange!ChunkyEventSlice(thread.eventList.slice(extents));
            // The 'frame' zone should be the last zone by end time in the slice
            // (ZoneRange is sorted by zone end time).
            ZoneData lastZone;
            foreach(zone; zonesInSlice) { lastZone = zone; }

            // Other members (ID, nesting, parent ID) will be different since we're
            // using a zone range generated from an event slice that doesn't include
            // all the parent zones.
            assert(expectedFrameZone.startTime == lastZone.startTime &&
                   expectedFrameZone.endTime == lastZone.endTime &&
                   expectedFrameZone.info == lastZone.info,
                   "Frame slices generated by Backend don't match frame zones");

            frameZones.popFront;
        }
    }
}
