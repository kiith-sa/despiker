import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.logger;
import std.path;
import std.range;
import std.stdio : writeln, writefln;
import std.string;
import std.typecons;

import platform.inputdevice;
import platform.videodevice;

import imgui;


/// Despiker GUI.
struct GUI
{
    /// Construct the GUI.
    this(VideoDevice video, InputDevice input)
    {
        this.video = video;
        this.input = input;
    }

    /// GUI update (frame).
    void update()
    {
        const mouse = input.mouse;
        ubyte mouseButtons;

        if(mouse.button(Mouse.Button.Left))   { mouseButtons |= MouseButton.left; }
        if(mouse.button(Mouse.Button.Right))  { mouseButtons |= MouseButton.right; }

        dchar unicode = 0;
        imguiBeginFrame(mouse.x, mouse.y, mouseButtons, mouse.wheelYMovement, unicode);

        const int width  = cast(int)video.width;
        const int height = cast(int)video.height;

        import std.math: pow;
        const int margin   = 4;
        const int sidebarW = max(40, cast(int)(width.pow(0.75)));
        const int sidebarH = max(40, height - 2 * margin);
        const int sidebarX = max(40, width - sidebarW - margin);

        // The "Actions" sidebar
        {
            imguiBeginScrollArea("Actions",
                                 sidebarX, margin, sidebarW, sidebarH, &sidebarScroll);
            scope(exit) { imguiEndScrollArea(); }
        }

        imguiEndFrame();
        imguiRender(width, height);
    }

private:
    /// Video device used to access window size, do manual rendering, etc.
    VideoDevice video;
    /// Access to input.
    InputDevice input;

    /// Current position of the sidebar scrollbar.
    int sidebarScroll;
}


import derelict.sdl2.sdl;
import derelict.opengl3.gl3;

import derelict.util.exception;

/// Load libraries using through Derelict (currently, this is SDL2).
bool loadDerelict(Logger log)
{
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
void unloadDerelict()
{
    DerelictSDL2.unload();
}

/// Initialize the SDL library.
bool initSDL(Logger log)
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
void deinitSDL()
{
    SDL_Quit();
}

/// Initialize the video device (setting video mode and initializing OpenGL).
bool initVideo(VideoDevice video, Logger log)
{
    // Initialize the video device.
    const width        = 800;
    const height       = 600;
    const fullscreen   = No.fullscreen;

    if(!video.initWindow(width, height, fullscreen)) { return false; }
    if(!video.initGL()) { return false; }
    video.windowTitle = "Despiker";
    return true;
}


int main(string[] args)
{
    if(!loadDerelict(log)) { return 1; }
    scope(exit)            { unloadDerelict(); }

    if(!initSDL(log)) { return 1; }
    scope(exit)       { SDL_Quit(); }

    auto video = scoped!VideoDevice(log);
    if(!initVideo(video, log)) { return 1; }

    auto input = scoped!InputDevice(&video.height, log);

    string fontPath = thisExePath().dirName().buildPath("DroidSans.ttf");
    // string fontPath = thisExePath().dirName().buildPath("GentiumPlus-R.ttf");

    glClearColor(0.8f, 0.8f, 0.8f, 1.0f);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_DEPTH_TEST);

    enforce(imguiInit(fontPath, 512));

    scope(exit) { imguiDestroy(); }

    const( char )* verstr = glGetString( GL_VERSION );

    GUI gui = GUI(video, input);

    for(;;)
    {
        input.update();
        if(input.quit) { break; }
        // React to window resize events.
        if(input.resized)
        {
            video.resizeViewport(input.resized.width, input.resized.height);
        }

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gui.update();

        // Log GL errors, if any.
        video.gl.runtimeCheck();

        // Swap the back buffer to the front, showing it in the window.
        // Outside of the frameLoad zone because VSync could break our profiling.
        video.swapBuffers();
    }

    return 0;
}
