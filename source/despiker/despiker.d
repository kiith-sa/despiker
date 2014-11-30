//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Despiker front-end, designed to be trivially controlled through a GUI.
module despiker.despiker;


import std.algorithm;
import std.array;
import std.stdio;
import std.typecons;

import tharsis.prof;

import despiker.backend;
import despiker.profdatasource;


/// Exception thrown at Despiker error.
class DespikerException : Exception
{
    this(string msg, string file = __FILE__, int line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}


/// View of execution in the current frame provided by Despiker.currentFrameView().
struct FrameView(Events)
{
    /// View of execution in one thread.
    struct ThreadFrameView
    {
        /// Info about execution in this thread during this frame (e.g. start, duration).
        FrameInfo frameInfo;
        /// Profiling events recorded during this frame in this thread.
        Events events;
        /// Range of all variables recorded during this frame in this thread.
        VariableRange!Events vars;
        /// Range of all zones recorded during this frame in this thread.
        ZoneRange!Events zones;
    }

    /// View of each thread during this frame.
    ThreadFrameView[] threads;
}

/** Despiker front-end, designed to be trivially controlled through a GUI.
 *
 * The Despiker class provides methods that should directly be called from the GUI
 * (e.g. from button presses), so that GUI implementation can be as simple as possible.
 */
class Despiker
{
public:
    /** Zones with info equal to this string (and matching nest level) are considered frames.
     *
     * If null, zone info does not matter for frame filtering.
     */
    string frameInfo = "frame";

    /** Zones with nest level equal to this string (and matching info) are considered frames.
     *
     * If 0, zone nest level does not matter for frame filtering.
     */
    ushort frameNestLevel = 0;

    /// Despiker 'modes', i.e. what the user is doing with Despiker.
    enum Mode
    {
        /// Track the newest frame, always updating the view with a graph for current frame.
        NewestFrame,
        /// Manually move between frames (next/previous frame, move to a specific frame)
        Manual
    }

    /** Maximum number of profiling data chunks to receive on an update.
     *
     * Too low values may result in Despiker running behind the profiled app, but too
     * high may result in Despiker getting into a 'death spiral' when each update takes
     * longer time, during which the profiled app generates more data, which makes the
     * next despiker frame longer, etc.
     */
    uint maxChunksPerUpdate = 128;

private:
    // Despiker backend, which stores profiling data and provides access to event lists.
    Backend backend_;

    // Profile data source used to read chunks that are then passed to backend.
    ProfDataSource dataSource_;

    // Current despiker mode.
    Mode mode_ = Mode.NewestFrame;

    // Readability alias.
    alias Events = ChunkyEventList.Slice;

    // View of the frame currently being viewed (events recorded in each thread, etc.).
    FrameView!Events view_;

    // In manual mode, this is the index of the frame we're currently viewing.
    size_t manualFrameIndex_ = 0;

public:
    /** Construct the Despiker.
     *
     * Params:
     *
     * dataSource = Profiling data source (e.g. from stdin or a file).
     * 
     *
     * Throws:
     *
     * DespikerException on failure.
     */
    this(ProfDataSource dataSource) @trusted
    {
        dataSource_ = dataSource;
        backend_ = new Backend(&frameFilter);
        view_    = view_.init;
    }

    /// Destroy the Despiker. Must be destroyed manually to free any threads, files, etc.
    ~this() @trusted nothrow
    {
        destroy(backend_).assumeWontThrow;
        destroy(dataSource_).assumeWontThrow;
    }

    /** Update Despiker. Processes newly received profile data.
     *
     * Should be called on each iteration of the event loop.
     */
    void update() @trusted nothrow
    {
        // Receive new chunks since the last update and add them to the backend.
        ProfileDataChunk chunk;
        foreach(c; 0 .. maxChunksPerUpdate)
        {
            if(!dataSource_.receiveChunk(chunk)) { break; }
            backend_.addChunk(chunk);
        }

        // Allow the backend to process the new chunks.
        backend_.update();

        const threadCount = backend_.threadCount;
        // If there are no profiled threads, there's no profiling data to view.
        // If there are no frames, we can't view anything either
        // (also, manualFrameIndex (0 by default) would be out of range in that case).
        if(threadCount == 0 || frameCount == 0)
        {
            destroy(view_.threads);
            return;
        }

        // View the most recent frame zone for which we have profiling data from all threads.
        view_.threads.assumeSafeAppend();
        view_.threads.length = threadCount;
        foreach(thread; 0 .. threadCount)
        {
            FrameInfo frame;
            final switch(mode_)
            {
                case Mode.NewestFrame:
                    // View the last frame we have profiling data from all threads for.
                    frame = backend_.frames(thread)[frameCount - 1];
                    break;
                case Mode.Manual:
                    // View the manually-selected frame.
                    frame = backend_.frames(thread)[manualFrameIndex_];
                    break;
            }

            with(view_.threads[thread])
            {
                frameInfo = frame;
                events    = backend_.events(thread).slice(frame.extents);
                vars      = VariableRange!Events(events);
                // Range of zones in the viewed frame for this thread.
                zones     = ZoneRange!Events(events);
            }
        }
    }

    /** Get the 'view' of the current frame.
     *
     * Used by the GUI to get zones, variables, etc. to display.
     *
     * Returns: A 'frame view' including profiling events, zones and variables recorded
     *          in each profiled thread during the current frame.
     */
    FrameView!Events currentFrameView() @safe pure nothrow const
    {
        return FrameView!Events(view_.threads.dup);
    }

    /// Get the current despiker mode.
    Mode mode() @safe pure nothrow const @nogc { return mode_; }

    /** Move to the next frame in manual mode. If newest frame mode, acts as pause().
     *
     * Should be directly triggered by a 'next frame' button.
     */
    void nextFrame() @safe pure nothrow @nogc
    {
        final switch(mode_)
        {
            case Mode.NewestFrame: pause(); break;
            case Mode.Manual:
                if(manualFrameIndex_ < frameCount - 1) { ++manualFrameIndex_; }
                break;
        }
    }

    /** Move to the previous frame in manual mode. If newest frame mode, acts as pause().
     *
     * Should be directly triggered by a 'previous frame' button.
     */
    void previousFrame() @safe pure nothrow @nogc
    {
        final switch(mode_)
        {
            case Mode.NewestFrame: pause(); break;
            case Mode.Manual:
                if(manualFrameIndex_ > 0 && frameCount > 0) { --manualFrameIndex_; }
                break;
        }
    }

    /** Set view to the frame with specified index (clamped to frameCount - 1).
     *
     * In 'newest first' mode, changes mode to 'manual'.
     *
     * Should be directly triggered by a 'view frame' button.
     */
    void frame(size_t rhs) @safe pure nothrow @nogc
    {
        final switch(mode_)
        {
            case Mode.NewestFrame:
                mode_ = Mode.Manual;
                manualFrameIndex_ = min(frameCount - 1, rhs);
                break;
            case Mode.Manual:
                manualFrameIndex_ = min(frameCount - 1, rhs);
                break;
        }
    }

    /// Get the index of the currently viewed frame. If there are 0 frames, returns size_t.max.
    size_t frame() @safe pure nothrow const @nogc
    {
        if(frameCount == 0) { return size_t.max; }
        final switch(mode_)
        {
            case Mode.NewestFrame: return frameCount - 1;
            case Mode.Manual:      return manualFrameIndex_;
        }
    }

    /** Set mode to 'manual', pausing at the current frame. In manual mode, does nothing.
     *
     * Should be directly triggered by a 'pause' button.
     */
    void pause() @safe pure nothrow @nogc
    {
        frame = frameCount - 1;
    }

    /** Resume viewing current frame. (NewestFrame mode). Ignored if we're already doing so.
     *
     * Should be directly triggered by a 'resume' button.
     */
    void resume() @safe pure nothrow @nogc
    {
        final switch(mode_)
        {
            case Mode.NewestFrame: break;
            case Mode.Manual: mode_ = Mode.NewestFrame; break;
        }
    }

    /** Find and view the worst frame so far.
     *
     * In 'newest frame' mode, sets mode to 'manual'.
     *
     * Finds the frame that took the most time so far (comparing the slowest thread's
     * time for each frame).
     *
     * Should be directly triggered by a 'worst frame' button.
     */
    void worstFrame() @safe pure nothrow @nogc
    {
        // Duration of the worst frame.
        ulong worstDuration = 0;
        // Index of the worst frame.
        size_t worstFrame = 0;
        // In each frame, get the total duration for all threads, then get the max of that.
        foreach(f; 0 .. frameCount)
        {
            // Get the real start/end time of the frame containing execution in all threads.
            ulong start = ulong.max;
            ulong end = ulong.min;
            foreach(thread; 0 .. backend_.threadCount)
            {
                const frame = backend_.frames(thread)[f];
                start = min(start, frame.startTime);
                end   = max(end,   frame.endTime);
            }
            const frameDuration = end - start;

            if(frameDuration > worstDuration)
            {
                worstFrame    = f;
                worstDuration = frameDuration;
            }
        }

        // Look at the worst frame.
        frame(worstFrame);
    }

    /// Get the number of frames for which we have profiling data from all threads.
    size_t frameCount() @safe pure nothrow const @nogc
    {
        if(backend_.threadCount == 0) { return 0; }

        size_t result = size_t.max;
        foreach(t; 0 .. backend_.threadCount)
        {
            result = min(result, backend_.frames(t).length);
        }
        return result;
    }

private:
    /** Function passed to Backend used to filter zones to determine which zones are frames.
     *
     * See_Also: frameInfo, frameNestLevel
     */
    bool frameFilter(ZoneData zone) @safe nothrow @nogc
    {
        return (frameInfo is null || zone.info == frameInfo) &&
               (frameNestLevel == 0 || zone.nestLevel == frameNestLevel);
    }
}
