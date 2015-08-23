import std.experimental.logger;

import despiker.despiker;
import openglgui;
 
import std.array;
import std.stdio;

void help()
{
    writeln(q"(
-------------------------------------------------------------------------------
Despiker
Real-time graphical profiler based on Tharsis.prof
Copyright (C) 2014 Ferdinand Majerech

Usage: despiker [--help] [--frameInfo] [--frameNestLevel]

WARNING: By default, Despiker expects to receive raw profiling data through its 
         standard input. This profiling data is usually sent using the the 
         DespikerSender API in Tharsis.prof library, which is also used to 
         launch Despiker. See the -r/--file-raw option for reading profiling 
         data from a file itself.

Examples:
    despiker -rprofile0.raw.prof -rprofile1.raw.prof
                                 Load profiling data for 2 files storing
                                 profiling outputs of Tharsis.prof Profilers in 
                                 2 separate threads.

Options:
    -h, --help                   Show this help message.
    -i, --frameInfo <info>       Filter zones by specified zone info string to
                                 determine which zones are frames. If zone info 
                                 does not matter, use --frameInfo=NULL.
                                 Only zones passing through all frame filters 
                                 (see --frameNestLevel) are considered frames.
                                 Default: "frame" (without doublequotes)
    -n, --frameNestLevel <level> Filter zones by specified zone nest level to
                                 determine which zones are frames. If zone nest
                                 level does not matter, use --frameNestLevel=0.
                                 Only zones passing through all frame filters 
                                 (see --frameInfo) are considered frames.
                                 Default: 0
    -r, --file-raw <file>        Instead of getting profiling input through 
                                 standard input, read raw profiling data dumped
                                 to specified file. If using multiple profilers
                                 for separate threads, use this option multiple 
                                 times, with filenames of each thread's 
                                 profiling data.
-------------------------------------------------------------------------------
)");
}



/// Program entry point.
int main(string[] args)
{
    string frameInfo = "frame";
    ushort frameNestLevel = 0;
    bool wantHelp = false;
    string[] rawFiles;

    import std.getopt;
    import std.conv: ConvException;

    try
    {
        getopt(args,
               std.getopt.config.bundling,
               std.getopt.config.caseSensitive,
               "frameInfo|i",      &frameInfo,
               "frameNestLevel|n", &frameNestLevel,
               "help|h",           &wantHelp,
               "file-raw|r",       &rawFiles);
    }
    catch(ConvException e)
    {
        writeln("Could not parse a value of a command-line argument: ", e.msg);
        help();
        return 1;
    }
    catch(GetOptException e)
    {
        writeln("Unrecognized command-line argument: ", e.msg);
        help();
        return 1;
    }

    if(wantHelp)
    {
        help();
        return 0;
    }


    auto log = sharedLog;

    import despiker.profdatasource: ProfDataSource,
                                    ProfDataSourceRaw,
                                    ProfDataSourceStdin,
                                    ProfDataSourceException;

    ProfDataSource dataSource;
    try
    {
        if(rawFiles.empty)
        {
            dataSource = new ProfDataSourceStdin();
        }
        else
        {
            dataSource = new ProfDataSourceRaw(rawFiles);
        }
    }
    catch(ProfDataSourceException e)
    {
        log.error("Failed to initialize profiling data source ", e.msg);
        return 3;
    }

    auto despiker = new Despiker(dataSource);
    scope(exit) { destroy(despiker); }
    despiker.frameInfo = frameInfo == "NULL" ? null : frameInfo;
    despiker.frameNestLevel = frameNestLevel;

    try
    {
        auto gui = new OpenGLGUI(log, despiker);
        scope(exit) { destroy(gui); }
        gui.run();
    }
    catch(GUIException e)
    {
        log.error("Failed to start Despiker: ", e.msg);
        return 2;
    }

    writeln("Note: write EOF (Ctrl-D on Linux) to end Despiker if directly launched");

    return 0;
}
