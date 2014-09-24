module gfmod.opengl;

// OpenGL OO wrapper

/**
 * gfmod.opengl philosophy:
 *
 * - Require GL 3.0+ without deprecated features (AKA GL 3.1 core context).
 * - Rely in debug callbacks instead of internal GL error checks.
 * - nothrow where possible. Throwing during init is OK, throwing during drawing/updates
 *   is not. (also, callbacks, see above).
 * - @nogc where possible, but not fanatically so.
 * - type safety (see Uniform specifications in uniform.d, Vertex structs, etc.)
 * - if it can be checked only once, do not check it on every call/draw/update
 *   (see also: type safety)
 */

public
{
    import derelict.opengl3.gl3,
           derelict.opengl3.gl;

    import gfmod.opengl.opengl,
           gfmod.opengl.buffer,
           gfmod.opengl.renderbuffer,
           gfmod.opengl.shader,
           gfmod.opengl.uniform,
           gfmod.opengl.program,
           gfmod.opengl.matrixstack,
           gfmod.opengl.texture,
           gfmod.opengl.textureunit,
           gfmod.opengl.fbo,
           gfmod.opengl.vertexarray;
}
