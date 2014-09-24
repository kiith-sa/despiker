module gfmod.opengl.shader;

import std.string,
       std.exception,
       std.conv;

import derelict.opengl3.gl3;

import gfmod.core.text,
       gfmod.opengl.opengl;

/// OpenGL Shader wrapper.
struct GLShader
{
public:
    @disable this();

    /// Creates a shader with source code and compiles it.
    /// Throws: $(D OpenGLException) on error.
    this(OpenGL gl, GLenum shaderType, string[] lines) @trusted
    {
        _gl = gl;
        _shader = glCreateShader(shaderType);
        if(_shader == 0) { throw new OpenGLException("glCreateShader failed"); }

        load(lines);
        if(!compile()) { throw new OpenGLException("Shader failed to compile"); }
    }

private:
    /// Load source code for this shader.
    void load(string[] lines) nothrow
    {
        size_t lineCount = lines.length;

        auto lengths    = new GLint[lineCount];
        auto addresses  = new immutable(GLchar)*[lineCount];
        auto localLines = new string[lineCount];

        foreach(i; 0 .. lineCount)
        {
            localLines[i] = lines[i] ~ "\n";
            lengths[i]    = cast(GLint)(localLines[i].length);
            addresses[i]  = localLines[i].ptr;
        }

        glShaderSource(_shader, cast(GLint)lineCount, cast(const(char)**)addresses.ptr,
                       lengths.ptr);
    }

    /// Compile this OpenGL shader.
    ///
    /// Returns: true on success, false on failure.
    bool compile() nothrow
    {
        glCompileShader(_shader);
        _gl.runtimeCheck();

        // print info log
        char[4096] logBuffer;
        string infoLog = getInfoLog(logBuffer[]);
        if(infoLog != null) { _gl._logger.info(infoLog).assumeWontThrow; }

        GLint compiled;
        glGetShaderiv(_shader, GL_COMPILE_STATUS, &compiled);

        return compiled == GL_TRUE ? true : false;
    }


    /// Gets the compiling report. 
    /// Returns: Log output of the GLSL compiler. Can return null!
    string getInfoLog(char[] logBuffer) nothrow const @nogc
    {
        GLint length;
        glGetShaderInfoLog(_shader, cast(int)logBuffer.length, &length, logBuffer.ptr);
        char[] log = logBuffer[0 .. length];
        log.sanitizeASCIIInPlace();
        return log.assumeUnique();
    }

package:
    // Handle to the GL shader.
    GLuint _shader;

private:
    // OpenGL info, logging, etc.
    OpenGL _gl;
}
