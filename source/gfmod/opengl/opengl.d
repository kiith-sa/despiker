module gfmod.opengl.opengl;

import core.stdc.stdlib;

import std.string,
       std.conv,
       std.exception,
       std.array,
       std.algorithm;

import derelict.util.exception,
       derelict.opengl3.gl3;

import std.experimental.logger;

import gfmod.core.text,
       gfmod.opengl.textureunit;

/// The one exception type thrown in this wrapper.
/// A failing OpenGL function should <b>always</b> throw an $(D OpenGLException).
class OpenGLException : Exception
{
    public
    {
        @safe pure nothrow this(string message, string file =__FILE__, size_t line = __LINE__, Throwable next = null)
        {
            super(message, file, line, next);
        }
    }
}

/// This object is passed around to other OpenGL wrapper objects
/// to ensure library loading.
/// Create one to use OpenGL.
final class OpenGL
{
    public
    {
        enum Vendor
        {
            AMD,
            Apple, // for software rendering aka no driver
            Intel,
            Mesa,
            Microsoft, // for "GDI generic" aka no driver
            NVIDIA,
            other
        }

        /// Load OpenGL library, redirect debug output to our logger.
        /// You can pass a null logger if you don't want logging.
        /// Throws: $(D OpenGLException) on error.
        this(Logger logger) @system
        {
            _logger = logger is null ? new NullLogger() : logger;
            try
            {
                DerelictGL3.load();
            }
            catch(DerelictException e)
            {
                throw new OpenGLException(e.msg, __FILE__, __LINE__, e);
            }
            

            //DerelictGL.load(); // load deprecated functions too

            _logger.infof("OpenGL loaded, version %s", DerelictGL3.loadedVersion());

            // do not log here since unimportant errors might happen:
            // no context is necessarily created at this point
            getLimits(false); 

            _textureUnits = new TextureUnits(this);
        }

        /// Unload the OpenGL library.
        ///
        /// Also checks for and logs any OpenGL objects that were not deleted to detect
        /// leaks.
        ~this()
        {
            logGLLeaks();
            close();
        }

        /// Assume any existing OpenGL objects are leaks and write them into the log.
        ///
        /// Should only be called when no GL objects should exist, e.g. after deleting
        /// all GL objects. Called automatically by the OpenGL destructor.
        void logGLLeaks()
        {
            // Yeah, this is a pretty ugly hack. But it works.
            GLuint maxID = 100000;
            foreach(id; 0 .. maxID)
            {
                void leak(string type, GLuint id)
                {
                    _logger.errorf("Leaked a %s OpenGL object. Handle: %s", type, id); 
                }
                if(glIsTexture(id))           { leak("texture",       id); }
                else if(glIsBuffer(id))       { leak("buffer",        id); }
                else if(glIsFramebuffer(id))  { leak("framebuffer",   id); }
                else if(glIsRenderbuffer(id)) { leak("renderbuffer",  id); }
                else if(glIsVertexArray(id))  { leak("vertex array",  id); }
                else if(glIsShader(id))       { leak("shader handle", id); }
                else if(glIsQuery(id))        { leak("query",         id); }
                else if(glIsProgram(id))      { leak("program",       id); }
                // These are not present in (our base requirement) OpenGL 3.0 so we
                // check if they're available.
                else if(glIsSampler !is null && glIsSampler(id))
                {
                    leak("sampler", id); 
                }
                else if(glIsTransformFeedback !is null && glIsTransformFeedback(id))
                {
                    leak("transform feedback", id); 
                }
                else if(glIsProgramPipeline !is null && glIsProgramPipeline(id))
                {
                    leak("program pipeline", id); 
                }
            }
        }

        /// Returns: true if the OpenGL extension is supported.
        bool supportsExtension(string extension)
        {
            foreach(s; _extensions)
                if (s == extension)
                    return true;
            return false;
        }

        /// Reload OpenGL function pointers.
        /// Once a first OpenGL context has been created, 
        /// you should call reload() to get the context you want.
        GLVersion reload() @system
        {
            GLVersion result;
            try
            {
                result = DerelictGL3.reload();
            }
            catch(DerelictException e)
            {
                throw new OpenGLException(e.msg, __FILE__, __LINE__, e);
            }
            
            _logger.infof("OpenGL reloaded, version %s", DerelictGL3.loadedVersion());
            _logger.infof("    Version: %s", getVersionString());
            _logger.infof("    Renderer: %s", getRendererString());
            _logger.infof("    Vendor: %s", getVendorString());
            _logger.infof("    GLSL version: %s", getGLSLVersionString());

            runtimeCheck();

            // parse extensions
            _extensions = getExtensionsStrings();
            runtimeCheck();

            _logger.infof("    Extensions: %s found", _extensions.length);
            _logger.infof("    - EXT_texture_filter_anisotropic is%s supported", EXT_texture_filter_anisotropic() ? "": " not");
            _logger.infof("    - EXT_framebuffer_object is%s supported", EXT_framebuffer_object() ? "": " not");
            _logger.info("Extensions:");
            _logger.info(_extensions);
            getLimits(true);
            _textureUnits = new TextureUnits(this);

            debug
            {
                // now that the context exists, pipe OpenGL output
                pipeOpenGLDebugOutput();
            }

            return result;
        }

        /// Releases the OpenGL dynamic library.
        /// All resources should have been released at this point,
        /// since you won't be able to call any OpenGL function afterwards.
        void close()
        {
            DerelictGL3.unload();
        }

        /// Check for pending OpenGL errors, log a message if there is.
        /// Only for debug purpose since this check will be disabled in a release build.
        void debugCheck()
        {
            debug
            {
                GLint r = glGetError();
                if (r != GL_NO_ERROR)
                {
                    flushGLErrors(); // flush other errors if any
                    _logger.errorf("OpenGL error: %s", getErrorString(r));
                    assert(false); // break here
                }
            }
        }

        /**
         * Checks pending OpenGL errors.
         *
         * Returns: true if at least one OpenGL error was pending. OpenGL error status is cleared.
         */
        bool runtimeCheck(string file = __FILE__, int line = __LINE__) @trusted nothrow
        {
            GLint r = glGetError();
            if (r != GL_NO_ERROR)
            {
                string errorString = getErrorString(r);
                flushGLErrors(); // flush other errors if any
                _logger.warningf("GL error detected in runtimeCheck called "
                                 "from file %s, line %s: ", file, line, errorString)
                                 .assumeWontThrow;
                return false;
            }
            return true;
        }

        /// Sanitize a GL string returned by glGetString/glGetStringi.
        string sanitizeGLString(const(char)* sZ) 
        {
            import core.stdc.string: strlen;
            if (sZ is null) { return "(unknown)"; }
            // Need to copy the string as it's const
            char[] text = sZ[0 .. strlen(sZ)].dup;
            if(!text.sanitizeASCIIInPlace())
            {
                _logger.warning("Invalid (non-ASCII) character in a GL string result");
            }

            return text.assumeUnique();
        }


        /// Returns: OpenGL string returned by $(D glGetString).
        /// See_also: $(WEB www.opengl.org/sdk/docs/man/xhtml/glGetString.xml)
        string getString(GLenum name)
        {
            const(char)* sZ = glGetString(name);
            runtimeCheck();
            return sanitizeGLString(sZ);
        }

        /// Returns: An array of OpenGL strings returned by $(D glGetStringi).
        /// See_also: $(WEB https://www.opengl.org/wiki/GLAPI/glGetString)
        string[] getStrings(GLenum pname, int numStrings)
        {
            auto result = new string[numStrings];
            foreach(uint i, ref str; result)
            {
                const(char)* sZ = glGetStringi(pname, i);
                // If error, return strings we got so far.
                if(!runtimeCheck()) { return result[0 .. i]; }

                str = sanitizeGLString(sZ);
            }

            return result;
        }

        /// Returns: OpenGL version string, can be "major_number.minor_number" or 
        ///          "major_number.minor_number.release_number".
        string getVersionString()
        {
            return getString(GL_VERSION);
        }

        /// Returns: The company responsible for this OpenGL implementation, so
        ///          that you can plant a giant toxic mushroom below their office.
        string getVendorString()
        {
            return getString(GL_VENDOR);
        }

        /// Tries to detect the driver maker.
        /// Returns: Identified vendor.
        Vendor getVendor()
        {
            string s = getVendorString();
            if (canFind(s, "AMD") || canFind(s, "ATI") || canFind(s, "Advanced Micro Devices"))
                return Vendor.AMD;
            else if (canFind(s, "NVIDIA") || canFind(s, "nouveau") || canFind(s, "Nouveau"))
                return Vendor.NVIDIA;
            else if (canFind(s, "Intel"))
                return Vendor.Intel;
            else if (canFind(s, "Mesa"))
                return Vendor.Mesa;
            else if (canFind(s, "Microsoft"))
                return Vendor.Microsoft;
            else if (canFind(s, "Apple"))
                return Vendor.Apple;
            else
                return Vendor.other;
        }

        /// Returns: Name of the renderer. This name is typically specific 
        ///          to a particular configuration of a hardware platform.
        string getRendererString()
        {
            return getString(GL_RENDERER);
        }

        /// Returns: GLSL version string, can be "major_number.minor_number" or 
        ///          "major_number.minor_number.release_number".
        string getGLSLVersionString()
        {
            return getString(GL_SHADING_LANGUAGE_VERSION);
        }


        /// Returns: An array of names of supported OpenGL extensions.
        string[] getExtensionsStrings()
        {
            scope(exit) { runtimeCheck(); }
            const numExtensions = getInteger(GL_NUM_EXTENSIONS, 0, true);
            runtimeCheck();
            return getStrings(GL_EXTENSIONS, numExtensions);
        }

        /// Calls $(D glGetIntegerv) and gives back the requested integer.
        /// Returns: true if $(D glGetIntegerv) succeeded.
        /// See_also: $(WEB www.opengl.org/sdk/docs/man4/xhtml/glGet.xml).
        /// Note: It is generally a bad idea to call $(D glGetSomething) since it might stall
        ///       the OpenGL pipeline.
        bool getInteger(GLenum pname, out int result,
                       string file = __FILE__, int line = __LINE__) nothrow
        {
            GLint param;
            glGetIntegerv(pname, &param);

            if (runtimeCheck())
            {
                result = param;
                return true;
            }
            else
                return false;
        }

        /// Returns: The requested integer returned by $(D glGetIntegerv) 
        ///          or defaultValue if an error occured.
        /// See_also: $(WEB www.opengl.org/sdk/docs/man4/xhtml/glGet.xml).        
        int getInteger(GLenum pname, GLint defaultValue, bool logging, 
                       string file = __FILE__, int line = __LINE__)
        {
            int result;

            if (getInteger(pname, result))
            {
                return result;
            }
            else
            {
                if (logging)
                {
                    _logger.warningf("couldn't get OpenGL integer (called from " 
                                     "file %s, line %s): ID %s", file, line, pname);
                }
                return defaultValue;
            }
        }

        /// Returns: The requested float returned by $(D glGetFloatv).
        /// See_also: $(WEB www.opengl.org/sdk/docs/man4/xhtml/glGet.xml). 
        /// Throws: $(D OpenGLException) if at least one OpenGL error was pending.
        float getFloat(GLenum pname)
        {
            GLfloat res;
            glGetFloatv(pname, &res);
            runtimeCheck();
            return res;
        }

        /// Returns: The requested float returned by $(D glGetFloatv) 
        ///          or defaultValue if an error occured.
        /// See_also: $(WEB www.opengl.org/sdk/docs/man4/xhtml/glGet.xml).   
        float getFloat(GLenum pname, GLfloat defaultValue, bool logging)
        {
            try
            {
                return getFloat(pname);
            }
            catch(OpenGLException e)
            {
                if (logging)
                    _logger.warning(e.msg);
                return defaultValue;
            }
        }
    }

    package
    {
        Logger _logger;

        static string getErrorString(GLint r) pure nothrow
        {
            switch(r)
            {
                case GL_NO_ERROR:          return "GL_NO_ERROR";
                case GL_INVALID_ENUM:      return "GL_INVALID_ENUM";
                case GL_INVALID_VALUE:     return "GL_INVALID_VALUE";
                case GL_INVALID_OPERATION: return "GL_INVALID_OPERATION";
                case GL_OUT_OF_MEMORY:     return "GL_OUT_OF_MEMORY";
                // case GL_TABLE_TOO_LARGE:   return "GL_TABLE_TOO_LARGE";
                // case GL_STACK_OVERFLOW:    return "GL_STACK_OVERFLOW";
                // case GL_STACK_UNDERFLOW:   return "GL_STACK_UNDERFLOW";
                default:                   return "Unknown OpenGL error";
            }
        }

    }

    public
    {
        /// Returns: Maximum texture size. 
        ///          This value should be at least 512 for a conforming OpenGL implementation.
        int maxTextureSize() pure const nothrow
        {
            return _maxTextureSize;
        }

        /// Returns: Number of texture units.
        int maxTextureUnits() pure const nothrow
        {
            return _maxTextureUnits;
        }

        /// Returns: Number of texture image units usable in a fragment shader.
        int maxFragmentTextureImageUnits() pure const nothrow
        {
            return _maxFragmentTextureImageUnits;
        }

        /// Returns: Number of texture image units usable in a vertex shader.
        int maxVertexImageUnits() pure const nothrow
        {
            return _maxVertexTextureImageUnits;
        }

        /// Returns: Number of combined texture image units.
        int maxCombinedImageUnits() pure const nothrow
        {
            return _maxCombinedTextureImageUnits;
        }

        /// Returns: Maximum number of color attachments. This is the number of targets a fragment shader can output to.
        /// You can rely on this number being at least 4 if MRT is supported.
        int maxColorAttachments() pure const nothrow
        {
            return _maxColorAttachments;
        }

        /// Returns: Texture units abstraction.
        TextureUnits textureUnits() pure nothrow
        {
            return _textureUnits;
        }

        /// Returns: Maximum value of anisotropic filter.
        float maxTextureMaxAnisotropy() pure const nothrow
        {
            return _maxTextureMaxAnisotropy;
        }
    }

    private
    {
        string[] _extensions;
        TextureUnits _textureUnits;
        int _majorVersion = 1;
        int _minorVersion = 1;
        int _maxTextureSize;
        int _maxTextureUnits; // number of conventional units, deprecated
        int _maxFragmentTextureImageUnits; // max for fragment shader
        int _maxVertexTextureImageUnits; // max for vertex shader
        int _maxCombinedTextureImageUnits; // max total
        int _maxColorAttachments;
        float _maxTextureMaxAnisotropy;

        void getLimits(bool logging)
        {
            runtimeCheck();
            // GL_MAJOR_VERSION/GL_MINOR_VERSION may not always work, so we parse version
            // string.
            auto verString = getVersionString().split()[0];
 
            import std.format;
            bool failedParse = false;
            // If this can't parse the version string, _majorVersion/_minorVersion will be 1.1
            try if(formattedRead(verString, "%s.%s", &_minorVersion, &_majorVersion) < 2)
            {
                failedParse = true;
            }
            catch(Exception e)
            {
                failedParse = true;
            }

            if(logging && failedParse)
            {
                _logger.warningf("couldn't parse OpenGL version string. "
                                 "Assuming version %s.%s", _majorVersion, _minorVersion);
            }

            runtimeCheck();

            _maxTextureSize = getInteger(GL_MAX_TEXTURE_SIZE, 512, logging);
            // For other textures, add calls to:
            // GL_MAX_ARRAY_TEXTURE_LAYERS​, GL_MAX_3D_TEXTURE_SIZE​
            _maxTextureUnits = getInteger(GL_MAX_TEXTURE_IMAGE_UNITS, 2, logging);

            _maxFragmentTextureImageUnits = getInteger(GL_MAX_TEXTURE_IMAGE_UNITS, 2, logging); // odd GL enum name because of legacy reasons (initially only fragment shader could access textures)
            _maxVertexTextureImageUnits = getInteger(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, 2, logging);
            _maxCombinedTextureImageUnits = getInteger(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 2, logging);
            // Get texture unit max for other shader stages with:
            // GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS, GL_MAX_TESS_CONTROL_TEXTURE_IMAGE_UNITS, GL_MAX_TESS_EVALUATION_TEXTURE_IMAGE_UNITS

            _maxColorAttachments = getInteger(GL_MAX_COLOR_ATTACHMENTS, 4, logging);

            if (EXT_texture_filter_anisotropic())
                _maxTextureMaxAnisotropy = getFloat(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, 1.0f, logging);
            else
                _maxTextureMaxAnisotropy = 1.0f;
        }

        // flush out OpenGL errors
        void flushGLErrors() nothrow
        {            
            int timeout = 0;
            while (++timeout <= 5) // avoid infinite loop in a no-driver situation
            {
                GLint r = glGetError();
                if (r == GL_NO_ERROR)
                    break;
            }
        }

        void pipeOpenGLDebugOutput()
        {
            if (KHR_debug())
            {
                glDebugMessageCallback(&loggingCallbackOpenGL, cast(void*)this);

                // enable all messages
                glDebugMessageControl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, null, GL_TRUE);

                glEnable(GL_DEBUG_OUTPUT);
                //glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
            }
        }
    }
}

extern(System) private
{
    // This callback can be called from multiple threads
    // TODO synchronization for Log objects
    nothrow void loggingCallbackOpenGL(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const(GLchar)* message, GLvoid* userParam)
    {
        try
        {
            OpenGL opengl = cast(OpenGL)userParam;

            try
            {
                Logger logger = opengl._logger;

                string ssource;
                switch (source)
                {
                    case GL_DEBUG_SOURCE_API:             ssource = "API"; break;
                    case GL_DEBUG_SOURCE_WINDOW_SYSTEM:   ssource = "window system"; break;
                    case GL_DEBUG_SOURCE_SHADER_COMPILER: ssource = "shader compiler"; break;
                    case GL_DEBUG_SOURCE_THIRD_PARTY:     ssource = "third party"; break;
                    case GL_DEBUG_SOURCE_APPLICATION:     ssource = "application"; break;
                    case GL_DEBUG_SOURCE_OTHER:           ssource = "other"; break;
                    default:                              ssource= "unknown"; break;
                }

                string stype;
                switch (type)
                {
                    case GL_DEBUG_TYPE_ERROR:               stype = "error"; break;
                    case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR: stype = "deprecated behaviour"; break;
                    case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR:  stype = "undefined behaviour"; break;
                    case GL_DEBUG_TYPE_PORTABILITY:         stype = "portabiliy"; break;
                    case GL_DEBUG_TYPE_PERFORMANCE:         stype = "performance"; break;
                    case GL_DEBUG_TYPE_OTHER:               stype = "other"; break;
                    default:                                stype = "unknown"; break;
                }

                LogLevel level;

                string sseverity;
                switch (severity)
                {
                    case GL_DEBUG_SEVERITY_HIGH:
                        level = LogLevel.error;
                        sseverity = "high";
                        break;

                    case GL_DEBUG_SEVERITY_MEDIUM: 
                        level = LogLevel.warning;
                        sseverity = "medium";
                        break;

                    case GL_DEBUG_SEVERITY_LOW:    
                        level = LogLevel.warning;
                        sseverity = "low";
                        break;

                    case GL_DEBUG_SEVERITY_NOTIFICATION:
                        level = LogLevel.info;
                        sseverity = "notification";
                        break;

                    default:
                        level = LogLevel.warning;
                        sseverity = "unknown";
                        break;
                }

                // Need to copy message as it's const
                import core.stdc.string;
                auto text = FixedString!1024.fromCString(message);
                if(!text.sanitizeASCIIInPlace())
                {
                    logger.warning("Invalid (non-ASCII) character in GL debug output");
                }

                // Spammy NVidia binary driver message that pretty much tells us that the
                // buffer objects works as it should.
                if(id == 131185) { return; }
                // Spammy NVidia binary driver message that tells as that mipmap level
                // of texture '0' is inconsistent with its min filter
                // (no idea what causes this, possibly dimgui).
                // - thought we may be binding '0' somewhere, but that's not the case,
                // and dimgui textures have no mimpaps afaics.
                if(id == 131204) { return; }

                if (level == LogLevel.info)
                    logger.infof("opengl: %s (id: %s, source: %s, type: %s, severity: %s)", text, id, ssource, stype, sseverity);
                if (level == LogLevel.warning)
                    logger.warningf("opengl: %s (id: %s, source: %s, type: %s, severity: %s)", text, id, ssource, stype, sseverity);
                if (level == LogLevel.error)
                    logger.errorf("opengl: %s (id: %s, source: %s, type: %s, severity: %s)", text, id, ssource, stype, sseverity);
            }
            catch (Exception e)
            {
                // got exception while logging, ignore it
            }
        }
        catch (Throwable e)
        {
            // No Throwable is supposed to cross C callbacks boundaries
            // Crash immediately
            exit(-1);
        }
    }
}

import std.traits;

struct FixedBuffer(size_t size, T)
    if(!hasElaborateDestructor!T)
{
private:
    T[size] buffer;

    size_t used;

public:
    T[] data() @safe pure nothrow @nogc
    {
        return buffer[0 .. used];
    }

    alias data this;
}

struct FixedString(size_t size)
{
    FixedBuffer!(size, char) base;
    alias base this;

    this(const char[] data) @safe pure nothrow @nogc 
    {
        assert(data.length <= size, "FixedString too small to contain assigned data");
        buffer[0 .. data.length] = data[];
        used = data.length;
    }

    static auto fromCString(const char* data) @system pure nothrow @nogc
    {
        import core.stdc.string;
        return FixedString!size(data[0 .. strlen(data)]);
    }
}
