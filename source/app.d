import std.experimental.logger;

import despiker.despiker;
import openglgui;

/// Program entry point.
int main(string[] args)
{
    auto despiker = scoped!Despiker();
    auto log = stdlog;

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
