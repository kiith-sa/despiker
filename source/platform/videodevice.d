//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Manages windowing and GL and provides access to convenience OpenGL wrappers.
module platform.videodevice;


import std.algorithm;
import std.exception;
import std.logger;
import std.typecons;

import derelict.opengl3.gl3;
import derelict.sdl2.sdl;


import gfmod.opengl.opengl;

// TODO: Support window resizing. 2014-09-12

/// Manages windowing and GL and provides access to convenience OpenGL wrappers.
class VideoDevice
{
private:
    // The game log.
    Logger log_;

    // OpenGL wrapper managing GL versions and information.

    OpenGL gl_;

    // The main game window.
    SDL_Window* window_;

    // Zero-terminated title of the main game window.
    char[1024] windowTitle_;

    // Window width.
    size_t width_;

    // Window height.
    size_t height_;

    // OpenGL context.
    SDL_GLContext context_;

public:
    /**
     * Construct a VideoDevice with specified OpenGL drawing to window.
     *
     * Note that to fully construct a VideoDevice you also need to call initWindow()
     * and initGL().
     *
     * Params:
     *
     * log    = The game log.
     */
    this(Logger log) @safe pure nothrow @nogc
    {
        windowTitle_[] = 0;
        log_    = log;
    }

    /// Destroy the VideoDevice. Must be called by the user (use e.g. scoped!).
    ~this()
    {
        if(gl_ !is null)                   { destroy(gl_); }
        if(context_ != SDL_GLContext.init) { SDL_GL_DeleteContext(context_); }
        if(window_ !is null)               { SDL_DestroyWindow(window_); }
    }

    import platform.sdl2;
    /**
     * Initialize the GL window.
     *
     * Must be called before initGL.
     */
    bool initWindow(size_t width, size_t height, Flag!"fullscreen" fullscreen)
        @trusted nothrow
    {
        assert(window_ is null, "Double initialization of the main window");
        window_ = createGLWindow(width, height, fullscreen);
        width_  = width;
        height_ = height;

        // Exit if window creation fails.
        if(null is window_)
        {
            log_.critical("Failed to create the application window").assumeWontThrow;
            return false;
        }
        log_.infof("Created a%s window with dimensions %s x %s",
                   fullscreen ? " fullscreen" : "", width, height).assumeWontThrow;
        return true;
    }

    /** Resize the viewport.
     *
     * Should be called after the window is resized.
     *
     * See_Also: InputDevice.resized
     */
    void resizeViewport(int width, int height)
    {
        width_  = width;
        height_ = height;
        glViewport(0, 0, width, height);
    }

    /**
     * Initialize the OpenGL context.
     *
     * Returns: true on success, false on failure.
     */
    bool initGL() @trusted nothrow
    {
        assert(window_ !is null, "Can't initialize GL without an initialized window");
        assert(gl_ is null, "Double initialization of GL");

        SDL_GLContext context;
        try
        {
            gl_      = new OpenGL(log_);
            context_ = SDL_GL_CreateContext(window_);
            if(gl_.reload() < GLVersion.GL30)
            {
                log_.critical("Required OpenGL version 3.0 could not be loaded.");
                return false;
            }
        }
        catch(OpenGLException e)
        {
            log_.critical("Failed to initialize OpenGL: ", e).assumeWontThrow;
            return false;
        }
        catch(Exception e)
        {
            assert(false, "Unexpected exception in initGL: " ~ e.msg);
        }
        return true;
    }

    /// Get window height.
    ///
    /// Signed because screen size is often multiplied by negative numbers.
    long height() @safe pure nothrow const @nogc
    {
        return height_;
    }

    /// Get window width.
    ///
    /// Signed because screen size is often multiplied by negative numbers.
    long width() @safe pure nothrow const @nogc
    {
        return width_;
    }

    /// Get access to the OpenGL API.
    OpenGL gl() @safe pure nothrow @nogc 
    {
        assert(gl_ !is null, "Trying to access GL before it is initialized");
        return gl_;
    }

    /// Set the main window title. Any characters past 1023 will be truncated.
    void windowTitle(string rhs) @trusted nothrow @nogc
    {
        // Zero-terminating in a fixed-size buffer.
        const titleLength = min(rhs.length, windowTitle_.length - 1);
        windowTitle_[0 .. titleLength] = rhs[0 .. titleLength];
        windowTitle_[titleLength] = 0;
        SDL_SetWindowTitle(window_, windowTitle_.ptr);
    }

    /// Swap the front and back buffer at the end of a frame.
    void swapBuffers() @trusted nothrow
    {
        assert(window_ !is null, "Can't swap buffers without an initialized window");
        SDL_GL_SwapWindow(window_);
    }
}
