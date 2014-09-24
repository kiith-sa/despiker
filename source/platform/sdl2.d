//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// SDL2-only utility functions. (Note: there is more SDL2 code in the Platform package)
module platform.sdl2;

import derelict.sdl2.sdl;


import std.typecons;


package:

/// Create an OpenGL window.
///
/// This only creates a window, not a GL context. The caller has to do that.
///
/// Params:
///
/// w           = Window width in pixels.
/// h           = Window height in pixels.
/// fullscreen) = If true, create a fullscreen window.
///
/// Returns: An SDL window. It's the caller's responsibility to destroy the window.
SDL_Window* createGLWindow(size_t w, size_t h, Flag!"fullscreen" fullscreen)
    @system nothrow @nogc
{
    assert(w > 0 && h > 0, "Can't create a zero-sized window");

    // OpenGL 3.0.
    // and the core profile (i.e. no deprecated functions)
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    // 32bit RGBA window
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE,     8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE,   8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE,    8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE,   8);
    // Double buffering to avoid tearing
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    // Depth buffer. Needed for 3D.
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE,   24);

    auto flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE;

    if(fullscreen) { flags |= SDL_WINDOW_FULLSCREEN; }
    // Create a centered 640x480 OpenGL window named "Tharsis-Game"
    return SDL_CreateWindow("tharsis-game", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                            cast(int)w, cast(int)h, flags);
}
