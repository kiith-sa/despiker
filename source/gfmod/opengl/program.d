module gfmod.opengl.program;

import core.stdc.string;

import std.conv,
       std.exception,
       std.string,
       std.regex,
       std.typecons,
       std.array,
       std.algorithm;

import derelict.opengl3.gl3;

import gfmod.core.text,
     //  gfm.math.vector,
     //  gfm.math.matrix,
       gfmod.opengl.opengl,
       gfmod.opengl.shader,
       gfmod.opengl.uniform,
       gfmod.opengl.uniformblock;

/// OpenGL Program wrapper.
final class GLProgram
{
    public
    {
        /// Creates an empty program.
        /// Throws: $(D OpenGLException) on error.
        this(OpenGL gl) @trusted
        {
            _gl = gl;
            _program = glCreateProgram();
            if (_program == 0)
            {
                throw new OpenGLException("Failed to create a GL program failed");
            }
        }

        /// Creates a program from a set of compiled shaders.
        /// Throws: $(D OpenGLException) on error.
        this(OpenGL gl, GLShader[] shaders...) @safe
        {
            this(gl);
            attach(shaders);
            link();
        }

        /**
         * Compiles N times the same GLSL source and link to a program.
         *
         * <p>
         * The same input is compiled 1 to 5 times, each time prepended
         * with a $(D #define) specific to a shader type.
         * </p>
         * $(UL
         *    $(LI $(D VERTEX_SHADER))
         *    $(LI $(D FRAGMENT_SHADER))
         *    $(LI $(D GEOMETRY_SHADER))
         *    $(LI $(D TESS_CONTROL_SHADER))
         *    $(LI $(D TESS_EVALUATION_SHADER))
         * )
         * <p>
         * Each of these macros are alternatively set to 1 while the others are
         * set to 0. If such a macro isn't used in any preprocessor directive
         * of your source, this shader stage is considered unused.</p>
         *
         * <p>For conformance reasons, any #version directive on the first line will stay at the top.</p>
         *
         * Warning: <b>THIS FUNCTION REWRITES YOUR SHADER A BIT.</b>
         * Expect slightly wrong lines in GLSL compiler's error messages.
         *
         * Example of a combined shader source:
         * ---
         *      #version 110
         *      uniform vec4 color;
         *
         *      #if VERTEX_SHADER
         *
         *      void main()
         *      {
         *          gl_Vertex = ftransform();
         *      }
         *
         *      #elif FRAGMENT_SHADER
         *
         *      void main()
         *      {
         *          gl_FragColor = color;
         *      }
         *
         *      #endif
         * ---
         *
         * Limitations:
         * $(UL
         *   $(LI All of #preprocessor directives should not have whitespaces before the #.)
         *   $(LI sourceLines elements should be individual lines!)
         * )
         *
         * Throws: $(D OpenGLException) on error.
         */
        this(OpenGL gl, string source) @trusted 
        {
            enum string[5] defines =
            [
              "VERTEX_SHADER",
              "FRAGMENT_SHADER",
              "GEOMETRY_SHADER",
              "TESS_CONTROL_SHADER",
              "TESS_EVALUATION_SHADER"
            ];
            enum GLenum[5] shaderTypes =
            [
                GL_VERTEX_SHADER,
                GL_FRAGMENT_SHADER,
                GL_GEOMETRY_SHADER,
                GL_TESS_CONTROL_SHADER,
                GL_TESS_EVALUATION_SHADER
            ];

            auto sourceLines = source.splitLines();
            _gl = gl;
            bool present[5];

            // from GLSL spec: "Each number sign (#) can be preceded in its line only by
            //                  spaces or horizontal tabs."
            enum directiveRegexp = ctRegex!(r"^[ \t]*#");
            enum versionRegexp = ctRegex!(r"^[ \t]*#[ \t]*version");

            present[] = false;
            int versionLine = -1;

            // Scan source for #version and usage of shader macros in preprocessor lines
            foreach(int lineIndex, line; sourceLines) if(line.match(directiveRegexp))
            {
                foreach(i, define; defines) if(line.canFind(define))
                {
                    present[i] = true;
                }

                if(!line.match(versionRegexp)) { continue; }

                if(versionLine != -1)
                {
                    enum message = "Your shader program has several #version "
                                   "directives, you are looking for problems.";
                    debug { throw new OpenGLException(message); }
                    else
                    {
                        gl._logger.warning(message);
                        continue;
                    }
                }

                if(lineIndex != 0)
                {
                    gl._logger.warning("For maximum compatibility, #version directive "
                                       "should be the first line of your shader.");
                }

                versionLine = lineIndex;
            }

            GLShader[] shaders;

            foreach(i, define; defines) if (present[i])
            {
                string[] newSource;

                // add #version line
                if(versionLine != -1) { newSource ~= sourceLines[versionLine]; }

                // add each #define with the right value
                foreach (j, define2; defines) if (present[j])
                {
                    newSource ~= "#define %s %d\n".format(define2, i == j ? 1 : 0);
                    ++_extraLines;
                }

                // add all lines except the #version one
                foreach(l, line; sourceLines) if (l != versionLine)
                {
                    newSource ~= line;
                }

                shaders ~= GLShader(_gl, shaderTypes[i], newSource);
            }
            this(gl, shaders);
        }

        /// Delete the GL program. Must be destroyed by the user.
        ~this() @safe nothrow @nogc { close(); }

        /// Releases the OpenGL program resource.
        void close() @trusted nothrow @nogc
        {
            if(_program != 0) { glDeleteProgram(_program); }
        }

        /// Attaches OpenGL shaders to this program.
        /// Throws: $(D OpenGLException) on error.
        void attach(GLShader[] compiledShaders...) @trusted nothrow @nogc
        {
            foreach(shader; compiledShaders)
            {
                glAttachShader(_program, shader._shader);
                glDeleteShader(shader._shader);
            }
        }

        /// Links this OpenGL program.
        /// Throws: $(D OpenGLException) on error.
        void link() @trusted
        {
            glLinkProgram(_program);
            _gl.runtimeCheck();
            GLint linkSuccess;
            glGetProgramiv(_program, GL_LINK_STATUS, &linkSuccess);
            if (GL_TRUE != linkSuccess)
            {
                string linkLog = getLinkLog();
                if(linkLog != null) { _gl._logger.errorf("%s", linkLog); }
                throw new OpenGLException("Cannot link program");
            }

            initUniforms();
            initAttribs();
        }

        /// Uses this program for following draw calls.
        /// Throws: $(D OpenGLException) on error.
        void use() @trusted nothrow
        {
            assert(!_inUse, "Calling use() on a GLProgram that's already being used");
            glUseProgram(_program);
            _gl.runtimeCheck();

            // upload uniform values then
            // this allow setting uniform at anytime without binding the program
            foreach(pair; _activeUniforms) { pair[1].use(); }
            _inUse = true;
        }

        /// Unuses this program.
        /// Throws: $(D OpenGLException) on error.
        void unuse() @trusted nothrow @nogc
        {
            assert(_inUse, "Calling unuse() on a GLProgram that's not being used");
            _inUse = false;
            foreach(pair; _activeUniforms) { pair[1].unuse(); }
            glUseProgram(0);
        }

        /// Is the program currently being used for drawing?
        bool inUse() @safe pure nothrow const @nogc
        {
            return _inUse;
        }

        /// Gets the linking report.
        /// Returns: Log output of the GLSL linker. Can return null!
        /// Throws: $(D OpenGLException) on error.
        string getLinkLog() @trusted nothrow
        {
            GLint logLength;
            glGetProgramiv(_program, GL_INFO_LOG_LENGTH, &logLength);
            if (logLength <= 0) { return null; }


            char[] log = new char[logLength];
            GLint dummy;
            glGetProgramInfoLog(_program, logLength, &dummy, log.ptr);
            if(_extraLines > 0)
            {
                log.assumeSafeAppend();
                log ~= "Extra lines added to the source code: %s "
                       .format(_extraLines).assumeWontThrow;
            }

            if(!log.sanitizeASCIIInPlace())
            {
                _gl._logger.warning("Invalid (non-ASCII) character in GL shader link log")
                           .assumeWontThrow;
            }
            return log.assumeUnique;
        }

        /** Gets an attribute by name.
         *
         * Params:
         *
         * name = Name of the attribute to get. The program must have this attribute
         *        (check with hasAttrib())
         * 
         * Returns: A $(D GLAttribute) with specified name.
         */
        GLAttribute attrib(string name) @safe pure nothrow const @nogc
        {
            auto found = _activeAttributes.find!(a => a[0] == name)();
            assert(!found.empty,
                   "Can't get an attrib that is not in the program. See hasAttrib().");
            return found.front[1];
        }

        /// Determine if the program has an attribute with specified name
        bool hasAttrib(string name) @safe pure nothrow const @nogc 
        {
            return !_activeAttributes.find!(a => a[0] == name)().empty;
        }

        /// Returns: Wrapped OpenGL resource handle.
        GLuint handle() @safe pure const nothrow @nogc
        {
            return _program;
        }
    }

    package
    {
        /** Gets a uniform by name.
         *
         * Returns: A GLUniform with this name. This GLUniform might be created on demand if
         *          the name hasn't been found. So it might be a "fake" uniform. This
         *          feature has been added to avoid errors when the driver decides that
         *          a uniform is not used and removes it.
         * See_also: GLUniform.
         */
        GLUniform uniform(string name) @safe nothrow
        {
            auto found = _activeUniforms.find!(a => a[0] == name)();

            if(found.empty)
            {
                // no such variable found, either it's really missing or the OpenGL driver discarded an unused uniform
                // create a fake disabled GLUniform to allow the show to proceed
                _gl._logger.warningf("Faking uniform variable '%s'", name).assumeWontThrow;
                _activeUniforms ~= tuple(name, new GLUniform(_gl, name));
                return _activeUniforms.back[1];
            }
            return found.front[1];
        }
    }

    private
    {
        // Initialize _activeUniforms. Should only be called by link().
        void initUniforms()
        {
            // When getting uniform and attribute names, add some length because of stories like this:
            // http://stackoverflow.com/questions/12555165/incorrect-value-from-glgetprogramivprogram-gl-active-uniform-max-length-outpa
            enum SAFETY_SPACE = 128;

            GLint uniformNameMaxLength;
            glGetProgramiv(_program, GL_ACTIVE_UNIFORM_MAX_LENGTH, &uniformNameMaxLength);

            GLchar[] buffer = new GLchar[uniformNameMaxLength + SAFETY_SPACE];

            GLint numActiveUniforms;
            glGetProgramiv(_program, GL_ACTIVE_UNIFORMS, &numActiveUniforms);

            // Get uniform block indices (if > 0, it's a block uniform)
            GLuint[] uniformIndex;
            GLint[] blockIndex;
            uniformIndex.length = numActiveUniforms;
            blockIndex.length = numActiveUniforms;

            foreach(GLuint i; 0.. numActiveUniforms) { uniformIndex[i] = i; }

            glGetActiveUniformsiv(_program,
                                  cast(GLint)uniformIndex.length,
                                  uniformIndex.ptr,
                                  GL_UNIFORM_BLOCK_INDEX,
                                  blockIndex.ptr);
            _gl.runtimeCheck();

            // Get active uniform blocks
            getUniformBlocks(_gl, this);

            foreach(GLuint i; 0 .. numActiveUniforms)
            {
                if(blockIndex[i] >= 0) { continue; }

                GLint size;
                GLenum type;
                GLsizei length;
                glGetActiveUniform(_program,
                                    i,
                                    cast(GLint)(buffer.length),
                                    &length,
                                    &size,
                                    &type,
                                    buffer.ptr);
                _gl.runtimeCheck();

                auto name = buffer[0 .. strlen(buffer.ptr)].dup;
                if(!name.sanitizeASCIIInPlace())
                {
                    _gl._logger.warning("Invalid (non-ASCII) character in GL uniform name");
                }

                auto nameStr = name.assumeUnique;
                _activeUniforms ~= 
                    tuple(nameStr, new GLUniform(_gl, _program, type, nameStr, size));
            }
        }

        // Initialize _activeAttributes. Should only be called by link().
        void initAttribs()
        {
            // When getting uniform and attribute names, add some length because of stories like this:
            // http://stackoverflow.com/questions/12555165/incorrect-value-from-glgetprogramivprogram-gl-active-uniform-max-length-outpa
            enum SAFETY_SPACE = 128;

            GLint attribNameMaxLength;
            glGetProgramiv(_program, GL_ACTIVE_ATTRIBUTE_MAX_LENGTH, &attribNameMaxLength);

            GLchar[] buffer = new GLchar[attribNameMaxLength + SAFETY_SPACE];

            GLint numActiveAttribs;
            glGetProgramiv(_program, GL_ACTIVE_ATTRIBUTES, &numActiveAttribs);

            foreach(GLuint i; 0 .. numActiveAttribs)
            {
                GLint size;
                GLenum type;
                GLsizei length;
                glGetActiveAttrib(_program, i, cast(GLint)(buffer.length),
                                    &length, &size, &type, buffer.ptr);
                _gl.runtimeCheck();

                auto name = buffer[0 .. strlen(buffer.ptr)].dup;
                if(!name.sanitizeASCIIInPlace())
                {
                    _gl._logger.warning("Invalid (non-ASCII) character in GL attribute name");
                }

                GLint location = glGetAttribLocation(_program, buffer.ptr);
                _gl.runtimeCheck();

                _activeAttributes ~= 
                    tuple(name.assumeUnique, GLAttribute(name, location, type, size));
            }
        }

        // Is this program currently in use?
        bool _inUse;
        OpenGL _gl;
        GLuint _program; // OpenGL handle
        // The number of lines added to the source code when loading a program from
        // a single source with both vertex and fragment shader.
        size_t _extraLines;
        Tuple!(string, GLUniform)[] _activeUniforms;
        Tuple!(string, GLAttribute)[] _activeAttributes;
    }
}


/// Represent an OpenGL program attribute. Owned by a GLProgram.
/// See_also: GLProgram.
struct GLAttribute
{
@safe pure nothrow:
public:
    this(char[] name, GLint location, GLenum type, GLsizei size) 
        @safe pure nothrow
    {
        _name = name.dup;
        _location = location;
        _type = type;
        _size = size;
    }

    GLint location() @safe pure nothrow const @nogc { return _location; }


private:
   GLint _location;
   GLenum _type;
   GLsizei _size;
   string _name;
}
