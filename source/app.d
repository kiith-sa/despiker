import std.logger;
import std.typecons: scoped;

import despiker.despiker;
import openglgui;

/// Program entry point.
int main(string[] args)
{
    auto despiker = scoped!Despiker();
    auto log = defaultLogger;

    try
    {
        auto gui = scoped!OpenGLGUI(log, despiker);
        gui.run();
    }
    catch(GUIException e)
    {
        log.error("Failed to start Despiker: ", e.msg);
        return 1;
    }

    return 0;
}
