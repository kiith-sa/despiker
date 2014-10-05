//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Default (and at the moment, only) Despiker GUI, based on SDL and OpenGL, using dimgui.
module openglgui;

import std.exception: enforce, assumeWontThrow;
import std.experimental.logger;

import derelict.opengl3.gl3;

import imgui;

import platform.inputdevice;
import platform.videodevice;

import despiker.despiker;


/// Exception thrown at GUI errors.
class GUIException : Exception
{
    this(string msg, string file = __FILE__, int line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Base class for despiker GUIs.
abstract class DespikerGUI
{
    /// Run the GUI (its event loop).
    void run() @safe nothrow;
}

/** Default (and at the moment, only) Despiker GUI, based on SDL and OpenGL, using dimgui.
 */
class OpenGLGUI: DespikerGUI
{
private:
    /// Video device used to access window size, do manual rendering, etc.
    VideoDevice video_;
    /// Access to input.
    InputDevice input_;

    /// Main log.
    Logger log_;

    /// Despiker implementation.
    Despiker despiker_;

    /// Current position of the sidebar scrollbar.
    int sidebarScroll;

public:
// TODO: GUI should provide access for modifying frame info/nest level.   2014-10-02

    /** Construct the GUI.
     *
     * Params:
     *
     * log      = Main program log.
     * despiker = Despiker implementation.
     */
    this(Logger log, Despiker despiker)
    {
        log_ = log;
        enforce(loadDerelict(log_),
                new GUIException("Failed to initialize GUI: failed to load Derelict"));
        scope(failure) { unloadDerelict(); }
        enforce(initSDL(log_),
                new GUIException("Failed to initialize GUI: failed to initialize SDL"));
        scope(failure) { deinitSDL(); }

        video_ = new VideoDevice(log_);
        scope(failure) { destroy(video_); }
        enforce(initVideo(video_, log_),
                new GUIException("Failed to initialize GUI: failed to initialize VideoDevice"));
        input_ = new InputDevice(&video_.height, log_);
        scope(failure) { destroy(input_); }

        despiker_ = despiker;

        glClearColor(0.8f, 0.8f, 0.8f, 1.0f);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_DEPTH_TEST);

        import std.file: thisExePath, exists, isFile;
        import std.path: dirName, buildPath;

        string[] fontDirs = [thisExePath().dirName()];
        // For (eventual) root Despiker installations.
        version(linux) { fontDirs ~= "/usr/share/despiker"; }

        // Find the font, and when found, init dimgui.
        enum fontName = "DroidSans.ttf";
        foreach(dir; fontDirs)
        {
            const fontPath = dir.buildPath(fontName);
            if(!fontPath.exists || !fontPath.isFile) { continue; }

            enforce(imguiInit(fontPath, 512),
                    new GUIException("Failed to initialize GUI: failed to initialize imgui"));
            scope(failure) { imguiDestroy(); }
            return;
        }

        import std.string: format;
        throw new GUIException("Despiker font %s not found in any of expected directories: %s"
                               .format(fontName, fontDirs));
    }

    /// Destroy the GUI. Must be called to properly free GL resources.
    ~this()
    {
        imguiDestroy();
        destroy(input_);
        destroy(video_);
        SDL_Quit();
        unloadDerelict();
    }

    /// Run the GUI (its event loop).
    override void run() @trusted nothrow
    {
        for(;;)
        {
            input_.update();
            despiker_.update();

            if(input_.quit) { break; }

            // React to window resize events.
            if(input_.resized)
            {
                video_.resizeViewport(input_.resized.width, input_.resized.height);
            }

            update();

            // Log GL errors, if any.
            video_.gl.runtimeCheck();

            // Swap the back buffer to the front, showing it in the window.
            // Outside of the frameLoad zone because VSync could break our profiling.
            video_.swapBuffers();
        }
    }

private:
    /// GUI update (frame).
    void update() nothrow
    {
        import std.algorithm;
        // Clear the screen.
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Get mouse input.
        const mouse = input_.mouse;
        ubyte mouseButtons;

        if(mouse.button(Mouse.Button.Left))   { mouseButtons |= MouseButton.left; }
        if(mouse.button(Mouse.Button.Right))  { mouseButtons |= MouseButton.right; }

        const int width  = cast(int)video_.width;
        const int height = cast(int)video_.height;

        imguiBeginFrame(mouse.x, mouse.y, mouseButtons, mouse.wheelYMovement,
                        input_.unicode).assumeWontThrow;
        scope(exit)
        {
            imguiEndFrame().assumeWontThrow;
            imguiRender(width, height).assumeWontThrow;
        }


        import std.math: pow;
        const int margin   = 4;
        const int sidebarW = max(40, cast(int)(width.pow(0.75)));
        const int sidebarH = max(40, height - 2 * margin);
        const int sidebarX = max(40, width - sidebarW - margin);

        // The "Actions" sidebar
        {
            imguiBeginScrollArea("Actions", sidebarX, margin, sidebarW, sidebarH,
                                 &sidebarScroll).assumeWontThrow;
            scope(exit) { imguiEndScrollArea().assumeWontThrow; }
        }
    }

    import derelict.sdl2.sdl;

    /// Load libraries using through Derelict (currently, this is SDL2).
    static bool loadDerelict(Logger log)
    {
        import derelict.util.exception;
        // Load SDL2.
        try
        {
            DerelictSDL2.load();
            return true;
        }
        catch(SharedLibLoadException e) { log.critical("SDL2 not found: ", e.msg); }
        catch(SymbolLoadException e)
        {
            log.critical("Missing SDL2 symbol (old SDL2 version?): ", e.msg);
        }

        return false;
    }

    /// Unload Derelict libraries.
    static void unloadDerelict()
    {
        DerelictSDL2.unload();
    }

    /// Initialize the SDL library.
    static bool initSDL(Logger log)
    {
        // Initialize SDL Video subsystem.
        if(SDL_Init(SDL_INIT_VIDEO) < 0)
        {
            // SDL_Init returns a negative number on error.
            log.critical("SDL Video subsystem failed to initialize");
            return false;
        }
        return true;
    }

    /// Deinitialize the SDL library.
    static void deinitSDL()
    {
        SDL_Quit();
    }

    /// Initialize the video device (setting video mode and initializing OpenGL).
    static bool initVideo(VideoDevice video_, Logger log)
    {
        // Initialize the video device.
        const width        = 800;
        const height       = 600;
        import std.typecons;
        const fullscreen   = No.fullscreen;

        if(!video_.initWindow(width, height, fullscreen)) { return false; }
        if(!video_.initGL()) { return false; }
        video_.windowTitle = "Despiker";
        return true;
    }
}
