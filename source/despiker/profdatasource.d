//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Profiling data sources (which receive profiling data sent by the profiled application).
module despiker.profdatasource;


import core.time;
import std.stdio;
import std.exception: assumeWontThrow, ErrnoException;


import despiker.backend;


/** Base class for profiling data sources.
 *
 * For now, the only implementation reads profile data from stdin. (Profiled application
 * launches despiker and writes to its stdin through a pipe).
 *
 * Note: $(B Must) be destroyed manually (or thrugh $(D std.typecons.scoped), etc.).
 *       A ProfDataSource may contain resources (threads, sockets, file handles) that
 *       must be freed.
 *
 * TODO: An implementation based on sockets. This may (or may not) be a bit slower than
 *       piping to stdin, but will allow despiker to run separately instead of requiring
 *       the profiled application to launch it (which is needed for the profiled
 *       application to specify a pipe to despiker's stdin).
 *       2014-10-01
 */
abstract class ProfDataSource
{
    /** Try to receive a _chunk of profiling data.
     *
     * Returns: true if a _chunk was received (and written to chunk), false otherwise.
     */
    bool receiveChunk(out ProfileDataChunk chunk) @system nothrow;
}

/// A chunk of profiling data.
struct ProfileDataChunk
{
    /** ID (index) of the profiled thread the profiler of which generated the profiling data.
     *
     * Useful when the user is profiling multiple threads (with separate Profilers).
     */
    uint threadId;

    /** Profiling data itself. Must contain whole events (must not start/end in the middle
     * of an event).
     */
    immutable(ubyte)[] data;
}

/// Exception thrown at ProfileDataSource errors.
class ProfDataSourceException : Exception
{
    this(string msg, string file = __FILE__, int line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/** A profiling data source that reads profiling data from stdin.
 *
 * To use this, the profiled application launches despiker, gets a pipe to despiker's
 * stdin and writes data to that pipe.
 *
 *
 * The 'protocol' for sending profiling data through stdin:
 *
 * Profiling data is sent in varying-size chunks with the following structure:
 * --------------------
 * uint threadIdx; // Index of the profiled thread (when using multiple per-thread Profilers)
 * uint byteCount; // Size of profiling data in the chunk, in bytes
 * ubyte[byteCount]; data; // Profiling data itself.
 * --------------------
 */
class ProfDataSourceStdin: ProfDataSource
{
    import std.concurrency;

private:
    /** Background thread that reads profiling data that appears in stdin and sends it to main
     * thread.
     */
    Tid readerTid_;

public:
    /** Construct a ProfDataSourceStdin.
     *
     * Throws:
     *
     * ProfDataSourceException on failure.
     */
    this() @system
    {
        try
        {
            // Start spawnedFunc in a new thread.
            readerTid_ = spawn(&reader, thisTid);
        }
        catch(Exception e)
        {
            throw new ProfDataSourceException("Failed to init ProfDataSourceStdin: ",e.msg);
        }
    }

    import std.typecons;
    /// Destroy the data source. Must be called by the user.
    ~this() @system nothrow
    {
        // Tell the reader thread to quit.
        send(readerTid_, Yes.quit).assumeWontThrow;
        stdin.close().assumeWontThrow;
    }

    override bool receiveChunk(out ProfileDataChunk chunk) @system nothrow
    {
        // while() because if we ignore any chunk (thread idx over maxThreads), we try
        // to receive the next chunk.
        while(receiveTimeout(dur!"msecs"(0),
              (ProfileDataChunk c) { chunk = c; },
              (Variant v) { assert(false, "Received unknown type"); }).assumeWontThrow)
        {
            if(chunk.threadId >= maxThreads)
            {
                // TODO: Add 'ignoreIfThrows()' and use it here instead of assumeWontThrow
                //       2014-10-02
                writeln("Chunk with thread ID greater or equal to 1024; no more than "
                        "1024 threads are supported. Ignoring.").assumeWontThrow;
                continue;
            }
            return true;
        }

        return false;
    }

private:
    /** The reader thread - reads any chunks from stdin and sends them to main thread.
     *
     * Params:
     *
     * owner = Tid of the owner thread.
     */
    static void reader(Tid owner)
    {
        // Chunk data is read from stdin to here.
        auto chunkReadBuffer = new ubyte[16 * 1024];

        scope(exit) { writeln("ProfDataSourceStdin: reader thread exit"); }

        try for(;;)
        {
            // Check if the main thread has told us to quit.
            Flag!"quit" quit;
            receiveTimeout(dur!"msecs"(0),
                (Flag!"quit" q) { quit = q; },
                (Variant v) { assert(false, "Received unknown type"); });
            if(quit) { break; }

            // Read the chunk header.
            uint[2] header;
            stdin.rawRead(header[]);
            const threadIdx = header[0];
            const byteCount = header[1];
            if(byteCount == 0) { continue; }

            // Enlarge chunkReadBuffer if needed.
            if(chunkReadBuffer.length < byteCount) { chunkReadBuffer.length = byteCount; }

            // Read byteCount bytes.
            auto newProfileData = chunkReadBuffer[0 .. byteCount];
            stdin.rawRead(newProfileData);

            // Send the chunk. Make a copy since chunkReadBuffer will be overwritten with
            // the next read chunk.
            send(owner, ProfileDataChunk(threadIdx, newProfileData[].idup)).assumeWontThrow;
        }
        // The quit message should be enough, but just to be sure handle the case when
        // the main thread is terminated but we don't get the quit message (e.g. on an
        // error in the main thread?)
        catch(OwnerTerminated e)
        {
            return;
        }
        catch(ErrnoException e)
        {
            // We occasionally get bad file descriptor when reading stdin fails after
            // the parent thread is closed. Probably no way to fix this cleanly, so we
            // just ignore it.
            return;
        }
        catch(Throwable e)
        {
            writeln("ProfDataSourceStdin: unexpected exception in reader thread:\n", e);
        }
    }
}
