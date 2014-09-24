module gfmod.opengl.uniform;

import std.algorithm,
       std.conv,
       std.exception,
       std.string,
       core.stdc.string;

import derelict.opengl3.gl3;

import gfmod.opengl.opengl,
       gfmod.opengl.program;


// TODO: (WISHLIST) eventually refactor/simplify GLUniform to be templated with uniform type,
// so e.g. set() will be generated just for that type without runtime checks.  2014-08-13

import std.traits;
import std.typetuple;

import gl3n_extra.linalg;

/// Checks if Spec is a valid uniform specification.
///
/// Uses static asserts for better compile-time error messages.
bool isUniformSpec(Spec)()
{
    // All supported uniform types.
    alias GLSLTypes = TypeTuple!(float,  vec2,   vec3,   vec4,
                                 double, vec2d,  vec3d,  vec4d,
                                 int,    vec2i,  vec3i,  vec4i,
                                 uint,   vec2u,  vec3u,  vec4u,
                                 mat2,   mat3,   mat4,
                                 mat32,  mat42,  mat23,  mat43,  mat24, mat34,
                                 mat2d,  mat3d,  mat4d,
                                 mat32d, mat42d, mat23d, mat43d, mat24d, mat34d);

    foreach(Field; FieldTypeTuple!Spec)
    {
        static assert(staticIndexOf!(Field, GLSLTypes) >= 0,
                     "Field of uniform spec %s has type %s which is not a supported "
                     " GL uniform type".format(Spec.stringof, Field.stringof));
    }
    return true;
}

// Manually copied from tharsis-core to avoid a dependency.
/// Get a compile-time tuple containing names of all fields in a struct.
private template FieldNamesTuple(S)
    if(is(S == struct))
{
    /// Determine if a member with specified name is a field of S.
    template isField(string memberName)
    {
        // For some reason, checking if 'S.this.offsetof' compiles is a compiler
        // error.
        static if(memberName == "this")
        {
            enum bool isField = false;
        }
        else
        {
            mixin(q{enum bool isField = __traits(compiles, S.%s.offsetof);}.format(memberName));
        }
    }

    alias FieldNamesTuple = Filter!(isField, __traits(allMembers, S));
}


/** A type-safe API for manipulating GLSL uniform variables.
 *
 * 'Uniforms specification' struct Spec specifies types and names of uniforms in
 * a program. GLUniforms!Spec has properties with names matching fields of Spec.
 * Uniforms in a program can be set by setting these properties.
 *
 * Example:
 * 
 * We have a vertex shader with source such as this:
 *
 * --------------------
 * #version 130
 *
 * uniform mat4 projection;
 * uniform mat4 modelView;
 * in vec3 position;
 * 
 * void main()
 * {
 *     gl_Position = projection * modelView *  vec4(position, 1.0);
 * }
 * --------------------
 *
 * We have the following uniforms specification struct:
 *
 * --------------------
 * struct Uniforms
 * {
 *     import gl3n.linalg;
 *     mat4 projection;
 *     mat4 modelView;
 * }
 * --------------------
 *
 * $(B NOTE:) Array uniforms are not supported at the moment, but will be supported in
 * future.
 *
 * The vertex shader above is used by a GLProgram $(D program).
 *
 * The following code builds a GLUniforms struct:
 *
 * Example:
 * --------------------
 * try
 * {
 *     auto uniforms = GLUniforms!Uniforms(program);
 * }
 * catch(OpenGLException e)
 * {
 *     writeln("ERROR: uniforms in a program have unexpected types: ", e);
 *     return;
 * }
 * --------------------
 *
 * The GLUniforms constructor enforces that types of uniforms in $(D program) match
 * types in $(D Uniforms) - the uniforms specification struct. Note that if 
 * $(D program) is missing any uniform, there is no error, only a logged warning, and
 * a dummy uniform is created. This is because some GPU drivers agressively optimize
 * and remove uniforms, and we don't want to trigger an error just because a user is
 * running our program on a GPU we didn't test.
 *
 * Finally, the following code sets the uniforms through $(D uniforms).
 *
 * --------------------
 * // mat4 projectionMatrix, modelViewMatrix
 * uniforms.projection = projectionMatrix;
 * uniforms.modelView  = modelViewMatrix;
 * --------------------
 */
struct GLUniforms(Spec)
    if(isUniformSpec!Spec)
{
private:
    // Names of fields in Spec.
    enum fieldNames = [FieldNamesTuple!Spec];

    // Types of fields in Spec.
    alias fieldTypes = FieldTypeTuple!Spec;

    // Generate GLUniform data members used internally to access uniforms.
    static string uniformsInternal()
    {
        return fieldNames.map!(n => q{GLUniform %s_;}.format(n)).join("\n");
    }

    // Generate setters that set each uniform.
    static string setters()
    {
        string[] setters;
        foreach(i, T; fieldTypes)
        {
            enum name = fieldNames[i];
            setters ~= q{
            // GLUniform ensures the value can be set even while the program is not
            // bound.
            void %s(%s rhs) @safe nothrow { %s_.set(rhs); }
            }.format(name, T.stringof, name);
        }

        return setters.join("\n\n");
    }

    // GLSL program owning the uniforms.
    GLProgram program_;

    // pragma(msg, uniformsInternal());
    mixin(uniformsInternal());

public:
    /// Construct GLUniforms to access uniforms in a GLProgram.
    ///
    /// If any uniform present in Spec is missing in program, a fake uniform will be
    /// created to avoid an error. See GLUniforms documentation top for why we avoid
    /// throwing an exception in that case.
    ///
    /// OpenGLException if types of uniforms in the program don't match types in Spec.
    this(GLProgram program) @safe
    {
        program_ = program;
        foreach(i, T; fieldTypes)
        {
            enum name = fieldNames[i];

            // Initialize the uniform
            mixin(q{
            %s_ = program_.uniform(name);
            // Fake uniforms are automatically ignored as they have no type.
            if(%s_.isFake) { continue; }
            // Check that the uniform has type from the spec.
            const compliant = %s_.typeIsCompliant!T;
            }.format(name, name, name));

            enum msg = "Uniform %s is not compatible with type %s."
                       .format(name, T.stringof);
            enforce(compliant, new OpenGLException(msg));
        }
    };

    // pragma(msg, setters());
    mixin(setters());
}

/// Represents an OpenGL program uniform. Owned by a GLProgram.
/// Both uniform locations and values are cached, to minimize OpenGL calls.
package final class GLUniform
{
    public
    {
        /// Creates a GLUniform.
        /// This is done automatically after linking a GLProgram.
        /// See_also: GLProgram.
        /// Throws: $(D OpenGLException) on error.
        this(OpenGL gl, GLuint program, GLenum type, string name, GLsizei size)
        {
            _gl = gl;
            _type = type;
            _size = size;
            _name = name;

            _location = glGetUniformLocation(program, toStringz(_name));
            if (_location == -1)
            {
                // probably rare: the driver said explicitely this variable was active, and there it's not.
                throw new OpenGLException(format("can't get uniform %s location", _name));
            }

            size_t cacheSize = sizeOfUniformType(type) * size;
            if (cacheSize > 0)
            {
                _value = new ubyte[cacheSize]; // relying on zero initialization here
                _valueChanged = false;

                _firstSet = true;
                _disabled = false;
            }
            else
            {
                _gl._logger.warningf("uniform %s is unrecognized or has size 0, disabled", _name);
                _disabled = true;
            }
        }

        /// Creates a fake disabled uniform variable, designed to cope with variables
        /// that have been optimized out by the OpenGL driver, or those which do not exist.
        this(OpenGL gl, string name) @safe nothrow
        {
            _gl       = gl;
            _disabled = true;
            _fake     = true;
            _gl._logger.warningf("creating fake uniform '%s' which either does not "
                                 "exist in the shader program, or was discarded by the"
                                 "driver as unused", name).assumeWontThrow;
        }

        /// Sets a uniform variable value.
        /// T should be the exact type needed, checked at runtime.
        /// Throws: $(D OpenGLException) on error.
        void set(T)(T newValue) @trusted
        {
            set!T(&newValue, 1u);
        }

        /// Sets multiple uniform variables.
        /// Throws: $(D OpenGLException) on error.
        void set(T)(T[] newValues) @safe
        {
            set!T(newValues.ptr, newValues.length);
        }

        /// Sets multiple uniform variables.
        /// Throws: $(D OpenGLException) on error.
        void set(T)(T* newValues, size_t count) @trusted nothrow
        {
            if (_disabled)
                return;

            assert(typeIsCompliant!T,
                   "Can't use type %s to set uniform '%s' which has GLSL type %s.\n"
                   "Use GLUniform.isTypeCompliant() to check if the type matches".
                   format(T.stringof, _name, GLSLTypeNameArray(_type, _size))
                   .assumeWontThrow);
            assert(count == _size,
                   "Can't set uniform '%s' of size %s with a value of size %s.\n"
                   "Use GLUniform.size() to check the uniform's size."
                   .format(_name, _size, count).assumeWontThrow);


            // if first time or different value incoming
            if (_firstSet || (0 != memcmp(newValues, _value.ptr, _value.length)))
            {
                memcpy(_value.ptr, newValues, _value.length);
                _valueChanged = true;

                if (_shouldUpdateImmediately)
                    update();
            }

            _firstSet = false;
        }

        /// Is this a "fake" uniform?
        ///
        /// Fake uniforms are created to avoid errors when a uniform is optimized out
        /// by the driver. A fake uniform has no type and will silently do nothing
        /// without failing when set.
        bool isFake() @safe pure nothrow const @nogc
        {
            return _fake;
        }

        /// Get the size (number of elements) of the uniform.
        size_t size() @safe pure nothrow const @nogc
        {
            return _size;
        }

        /// Called when the program owning this uniform is used.
        void use() nothrow
        {
            // When in use, any changes to the uniform must trigger an immediate update.
            _shouldUpdateImmediately = true;
            update();
        }

        /// Called when the program owning this uniform is unused.
        void unuse() @safe pure nothrow @nogc
        {
            // When not in use, we can wait with updating the uniform till we're being
            // used.
            _shouldUpdateImmediately = false;
        }
    }

    private
    {
        OpenGL _gl;
        GLint _location;
        GLenum _type;
        GLsizei _size;
        ubyte[] _value;
        bool _valueChanged;
        bool _firstSet; // force update to ensure we do not relie on the driver initializing uniform to zero
        bool _disabled; // allow transparent usage while not doing anything
        bool _fake;     // Extra flag for fake uniforms used when a uniform is optimized out.
        bool _shouldUpdateImmediately;
        string _name;

        void update() nothrow
        {
            if (_disabled)
                return;

            // safety check to prevent defaults values in uniforms
            if (_firstSet)
            {
                _gl._logger.warningf("uniform '%s' left to default value, driver will probably zero it", _name)
                           .assumeWontThrow();
                _firstSet = false;
            }

            // has value changed?
            // if so, set OpenGL value
            if (_valueChanged)
            {
                // _gl._logger.info(*cast(mat4*)_value.ptr).assumeWontThrow;
                setUniform();
                _valueChanged = false;
            }
        }

        void setUniform() @trusted nothrow @nogc
        {
            switch(_type)
            {
                case GL_FLOAT:             glUniform1fv(_location, _size, cast(GLfloat*)_value); break;
                case GL_FLOAT_VEC2:        glUniform2fv(_location, _size, cast(GLfloat*)_value); break;
                case GL_FLOAT_VEC3:        glUniform3fv(_location, _size, cast(GLfloat*)_value); break;
                case GL_FLOAT_VEC4:        glUniform4fv(_location, _size, cast(GLfloat*)_value); break;
                case GL_DOUBLE:            glUniform1dv(_location, _size, cast(GLdouble*)_value); break;
                case GL_DOUBLE_VEC2:       glUniform2dv(_location, _size, cast(GLdouble*)_value); break;
                case GL_DOUBLE_VEC3:       glUniform3dv(_location, _size, cast(GLdouble*)_value); break;
                case GL_DOUBLE_VEC4:       glUniform4dv(_location, _size, cast(GLdouble*)_value); break;
                case GL_INT:               glUniform1iv(_location, _size, cast(GLint*)_value); break;
                case GL_INT_VEC2:          glUniform2iv(_location, _size, cast(GLint*)_value); break;
                case GL_INT_VEC3:          glUniform3iv(_location, _size, cast(GLint*)_value); break;
                case GL_INT_VEC4:          glUniform4iv(_location, _size, cast(GLint*)_value); break;
                case GL_UNSIGNED_INT:      glUniform1uiv(_location, _size, cast(GLuint*)_value); break;
                case GL_UNSIGNED_INT_VEC2: glUniform2uiv(_location, _size, cast(GLuint*)_value); break;
                case GL_UNSIGNED_INT_VEC3: glUniform3uiv(_location, _size, cast(GLuint*)_value); break;
                case GL_UNSIGNED_INT_VEC4: glUniform4uiv(_location, _size, cast(GLuint*)_value); break;
                case GL_BOOL:              glUniform1iv(_location, _size, cast(GLint*)_value); break;
                case GL_BOOL_VEC2:         glUniform2iv(_location, _size, cast(GLint*)_value); break;
                case GL_BOOL_VEC3:         glUniform3iv(_location, _size, cast(GLint*)_value); break;
                case GL_BOOL_VEC4:         glUniform4iv(_location, _size, cast(GLint*)_value); break;
                case GL_FLOAT_MAT2:        glUniformMatrix2fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT3:        glUniformMatrix3fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT4:        glUniformMatrix4fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT2x3:      glUniformMatrix2x3fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT2x4:      glUniformMatrix3x2fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT3x2:      glUniformMatrix2x4fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT3x4:      glUniformMatrix4x2fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT4x2:      glUniformMatrix3x4fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_FLOAT_MAT4x3:      glUniformMatrix4x3fv(_location, _size, GL_TRUE, cast(GLfloat*)_value); break;
                case GL_DOUBLE_MAT2:       glUniformMatrix2dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT3:       glUniformMatrix3dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT4:       glUniformMatrix4dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT2x3:     glUniformMatrix2x3dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT2x4:     glUniformMatrix3x2dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT3x2:     glUniformMatrix2x4dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT3x4:     glUniformMatrix4x2dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT4x2:     glUniformMatrix3x4dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;
                case GL_DOUBLE_MAT4x3:     glUniformMatrix4x3dv(_location, _size, GL_TRUE, cast(GLdouble*)_value); break;

                // image samplers
                case GL_IMAGE_1D: .. case GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY:
                    glUniform1iv(_location, _size, cast(GLint*)_value);
                    break;

                case GL_UNSIGNED_INT_ATOMIC_COUNTER:
                    glUniform1uiv(_location, _size, cast(GLuint*)_value);
                    break;

                case GL_SAMPLER_1D:
                case GL_SAMPLER_2D:
                case GL_SAMPLER_3D:
                case GL_SAMPLER_CUBE:
                case GL_SAMPLER_1D_SHADOW:
                case GL_SAMPLER_2D_SHADOW:
                case GL_SAMPLER_1D_ARRAY:
                case GL_SAMPLER_2D_ARRAY:
                case GL_SAMPLER_1D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_MULTISAMPLE:
                case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_SAMPLER_CUBE_SHADOW:
                case GL_SAMPLER_BUFFER:
                case GL_SAMPLER_2D_RECT:
                case GL_SAMPLER_2D_RECT_SHADOW:
                case GL_INT_SAMPLER_1D:
                case GL_INT_SAMPLER_2D:
                case GL_INT_SAMPLER_3D:
                case GL_INT_SAMPLER_CUBE:
                case GL_INT_SAMPLER_1D_ARRAY:
                case GL_INT_SAMPLER_2D_ARRAY:
                case GL_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_INT_SAMPLER_BUFFER:
                case GL_INT_SAMPLER_2D_RECT:
                case GL_UNSIGNED_INT_SAMPLER_1D:
                case GL_UNSIGNED_INT_SAMPLER_2D:
                case GL_UNSIGNED_INT_SAMPLER_3D:
                case GL_UNSIGNED_INT_SAMPLER_CUBE:
                case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
                    glUniform1iv(_location, _size, cast(GLint*)_value);
                    break;

                default:
                    break;
            }
        }

        public bool typeIsCompliant(T)() @safe pure nothrow const @nogc
        {
            switch (_type)
            {
                case GL_FLOAT:             return is(T == float);
                case GL_FLOAT_VEC2:        return is(T == vec2);
                case GL_FLOAT_VEC3:        return is(T == vec3);
                case GL_FLOAT_VEC4:        return is(T == vec4);
                case GL_DOUBLE:            return is(T == double);
                case GL_DOUBLE_VEC2:       return is(T == vec2d);
                case GL_DOUBLE_VEC3:       return is(T == vec3d);
                case GL_DOUBLE_VEC4:       return is(T == vec4d);
                case GL_INT:               return is(T == int);
                case GL_INT_VEC2:          return is(T == vec2i);
                case GL_INT_VEC3:          return is(T == vec3i);
                case GL_INT_VEC4:          return is(T == vec4i);
                case GL_UNSIGNED_INT:      return is(T == uint);
                case GL_UNSIGNED_INT_VEC2: return is(T == vec2u);
                case GL_UNSIGNED_INT_VEC3: return is(T == vec3u);
                case GL_UNSIGNED_INT_VEC4: return is(T == vec4u);
                case GL_BOOL:              return is(T == int); // int because bool type is 1 byte
                case GL_BOOL_VEC2:         return is(T == vec2i);
                case GL_BOOL_VEC3:         return is(T == vec3i);
                case GL_BOOL_VEC4:         return is(T == vec4i);
                case GL_FLOAT_MAT2:        return is(T == mat2);
                case GL_FLOAT_MAT3:        return is(T == mat3);
                case GL_FLOAT_MAT4:        return is(T == mat4);
                case GL_FLOAT_MAT2x3:      return is(T == mat32);
                case GL_FLOAT_MAT2x4:      return is(T == mat42);
                case GL_FLOAT_MAT3x2:      return is(T == mat23);
                case GL_FLOAT_MAT3x4:      return is(T == mat43);
                case GL_FLOAT_MAT4x2:      return is(T == mat24);
                case GL_FLOAT_MAT4x3:      return is(T == mat34);
                case GL_DOUBLE_MAT2:       return is(T == mat2d);
                case GL_DOUBLE_MAT3:       return is(T == mat3d);
                case GL_DOUBLE_MAT4:       return is(T == mat4d);
                case GL_DOUBLE_MAT2x3:     return is(T == mat32d);
                case GL_DOUBLE_MAT2x4:     return is(T == mat42d);
                case GL_DOUBLE_MAT3x2:     return is(T == mat23d);
                case GL_DOUBLE_MAT3x4:     return is(T == mat43d);
                case GL_DOUBLE_MAT4x2:     return is(T == mat24d);
                case GL_DOUBLE_MAT4x3:     return is(T == mat34d);

                    // image samplers
                case GL_IMAGE_1D: .. case GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY:
                    return is(T == int);

                case GL_UNSIGNED_INT_ATOMIC_COUNTER:
                    return is(T == uint);

                case GL_SAMPLER_1D:
                case GL_SAMPLER_2D:
                case GL_SAMPLER_3D:
                case GL_SAMPLER_CUBE:
                case GL_SAMPLER_1D_SHADOW:
                case GL_SAMPLER_2D_SHADOW:
                case GL_SAMPLER_1D_ARRAY:
                case GL_SAMPLER_2D_ARRAY:
                case GL_SAMPLER_1D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_MULTISAMPLE:
                case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_SAMPLER_CUBE_SHADOW:
                case GL_SAMPLER_BUFFER:
                case GL_SAMPLER_2D_RECT:
                case GL_SAMPLER_2D_RECT_SHADOW:
                case GL_INT_SAMPLER_1D:
                case GL_INT_SAMPLER_2D:
                case GL_INT_SAMPLER_3D:
                case GL_INT_SAMPLER_CUBE:
                case GL_INT_SAMPLER_1D_ARRAY:
                case GL_INT_SAMPLER_2D_ARRAY:
                case GL_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_INT_SAMPLER_BUFFER:
                case GL_INT_SAMPLER_2D_RECT:
                case GL_UNSIGNED_INT_SAMPLER_1D:
                case GL_UNSIGNED_INT_SAMPLER_2D:
                case GL_UNSIGNED_INT_SAMPLER_3D:
                case GL_UNSIGNED_INT_SAMPLER_CUBE:
                case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
                    return is(T == int);

                default:
                    // unrecognized type, in release mode return true
                    debug
                    {
                        assert(false);
                    }
                    else
                    {
                        return true;
                    }
            }
        }

        public static size_t sizeOfUniformType(GLenum type) @safe pure nothrow @nogc 
        {
            switch (type)
            {
                case GL_FLOAT:             return float.sizeof;
                case GL_FLOAT_VEC2:        return vec2.sizeof;
                case GL_FLOAT_VEC3:        return vec3.sizeof;
                case GL_FLOAT_VEC4:        return vec4.sizeof;
                case GL_DOUBLE:            return double.sizeof;
                case GL_DOUBLE_VEC2:       return vec2d.sizeof;
                case GL_DOUBLE_VEC3:       return vec3d.sizeof;
                case GL_DOUBLE_VEC4:       return vec4d.sizeof;
                case GL_INT:               return int.sizeof;
                case GL_INT_VEC2:          return vec2i.sizeof;
                case GL_INT_VEC3:          return vec3i.sizeof;
                case GL_INT_VEC4:          return vec4i.sizeof;
                case GL_UNSIGNED_INT:      return uint.sizeof;
                case GL_UNSIGNED_INT_VEC2: return vec2u.sizeof;
                case GL_UNSIGNED_INT_VEC3: return vec3u.sizeof;
                case GL_UNSIGNED_INT_VEC4: return vec4u.sizeof;
                case GL_BOOL:              return int.sizeof; // int because D bool type is 1 byte
                case GL_BOOL_VEC2:         return vec2i.sizeof;
                case GL_BOOL_VEC3:         return vec3i.sizeof;
                case GL_BOOL_VEC4:         return vec4i.sizeof;
                case GL_FLOAT_MAT2:        return mat2.sizeof;
                case GL_FLOAT_MAT3:        return mat3.sizeof;
                case GL_FLOAT_MAT4:        return mat4.sizeof;
                case GL_FLOAT_MAT2x3:      return mat32.sizeof;
                case GL_FLOAT_MAT2x4:      return mat42.sizeof;
                case GL_FLOAT_MAT3x2:      return mat23.sizeof;
                case GL_FLOAT_MAT3x4:      return mat43.sizeof;
                case GL_FLOAT_MAT4x2:      return mat24.sizeof;
                case GL_FLOAT_MAT4x3:      return mat34.sizeof;
                case GL_DOUBLE_MAT2:       return mat2d.sizeof;
                case GL_DOUBLE_MAT3:       return mat3d.sizeof;
                case GL_DOUBLE_MAT4:       return mat4d.sizeof;
                case GL_DOUBLE_MAT2x3:     return mat32d.sizeof;
                case GL_DOUBLE_MAT2x4:     return mat42d.sizeof;
                case GL_DOUBLE_MAT3x2:     return mat23d.sizeof;
                case GL_DOUBLE_MAT3x4:     return mat43d.sizeof;
                case GL_DOUBLE_MAT4x2:     return mat24d.sizeof;
                case GL_DOUBLE_MAT4x3:     return mat34d.sizeof;

                    // image samplers
                case GL_IMAGE_1D: .. case GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY:
                    return int.sizeof;

                case GL_UNSIGNED_INT_ATOMIC_COUNTER:
                    return uint.sizeof;

                case GL_SAMPLER_1D:
                case GL_SAMPLER_2D:
                case GL_SAMPLER_3D:
                case GL_SAMPLER_CUBE:
                case GL_SAMPLER_1D_SHADOW:
                case GL_SAMPLER_2D_SHADOW:
                case GL_SAMPLER_1D_ARRAY:
                case GL_SAMPLER_2D_ARRAY:
                case GL_SAMPLER_1D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_MULTISAMPLE:
                case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_SAMPLER_CUBE_SHADOW:
                case GL_SAMPLER_BUFFER:
                case GL_SAMPLER_2D_RECT:
                case GL_SAMPLER_2D_RECT_SHADOW:
                case GL_INT_SAMPLER_1D:
                case GL_INT_SAMPLER_2D:
                case GL_INT_SAMPLER_3D:
                case GL_INT_SAMPLER_CUBE:
                case GL_INT_SAMPLER_1D_ARRAY:
                case GL_INT_SAMPLER_2D_ARRAY:
                case GL_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_INT_SAMPLER_BUFFER:
                case GL_INT_SAMPLER_2D_RECT:
                case GL_UNSIGNED_INT_SAMPLER_1D:
                case GL_UNSIGNED_INT_SAMPLER_2D:
                case GL_UNSIGNED_INT_SAMPLER_3D:
                case GL_UNSIGNED_INT_SAMPLER_CUBE:
                case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
                    return int.sizeof;

                default:
                    // unrecognized type
                    // in debug mode assert, in release mode return 0 to disable this uniform
                    debug
                    {
                        assert(false);
                    }
                    else
                    {
                        return 0;
                    }
            }
        }

        static string GLSLTypeName(GLenum type) @safe pure nothrow @nogc 
        {
            switch (type)
            {
                case GL_FLOAT:                                     return "float";
                case GL_FLOAT_VEC2:                                return "vec2";
                case GL_FLOAT_VEC3:                                return "vec3";
                case GL_FLOAT_VEC4:                                return "vec4";
                case GL_DOUBLE:                                    return "double";
                case GL_DOUBLE_VEC2:                               return "dvec2";
                case GL_DOUBLE_VEC3:                               return "dvec3";
                case GL_DOUBLE_VEC4:                               return "dvec4";
                case GL_INT:                                       return "int";
                case GL_INT_VEC2:                                  return "ivec2";
                case GL_INT_VEC3:                                  return "ivec3";
                case GL_INT_VEC4:                                  return "ivec4";
                case GL_UNSIGNED_INT:                              return "uint";
                case GL_UNSIGNED_INT_VEC2:                         return "uvec2";
                case GL_UNSIGNED_INT_VEC3:                         return "uvec3";
                case GL_UNSIGNED_INT_VEC4:                         return "uvec4";
                case GL_BOOL:                                      return "bool";
                case GL_BOOL_VEC2:                                 return "bvec2";
                case GL_BOOL_VEC3:                                 return "bvec3";
                case GL_BOOL_VEC4:                                 return "bvec4";
                case GL_FLOAT_MAT2:                                return "mat2";
                case GL_FLOAT_MAT3:                                return "mat3";
                case GL_FLOAT_MAT4:                                return "mat4";
                case GL_FLOAT_MAT2x3:                              return "mat2x3";
                case GL_FLOAT_MAT2x4:                              return "mat2x4";
                case GL_FLOAT_MAT3x2:                              return "mat3x2";
                case GL_FLOAT_MAT3x4:                              return "mat3x4";
                case GL_FLOAT_MAT4x2:                              return "mat4x2";
                case GL_FLOAT_MAT4x3:                              return "mat4x3";
                case GL_DOUBLE_MAT2:                               return "dmat2";
                case GL_DOUBLE_MAT3:                               return "dmat3";
                case GL_DOUBLE_MAT4:                               return "dmat4";
                case GL_DOUBLE_MAT2x3:                             return "dmat2x3";
                case GL_DOUBLE_MAT2x4:                             return "dmat2x4";
                case GL_DOUBLE_MAT3x2:                             return "dmat3x2";
                case GL_DOUBLE_MAT3x4:                             return "dmat3x4";
                case GL_DOUBLE_MAT4x2:                             return "dmat4x2";
                case GL_DOUBLE_MAT4x3:                             return "dmat4x3";
                case GL_SAMPLER_1D:                                return "sampler1D";
                case GL_SAMPLER_2D:                                return "sampler2D";
                case GL_SAMPLER_3D:                                return "sampler3D";
                case GL_SAMPLER_CUBE:                              return "samplerCube";
                case GL_SAMPLER_1D_SHADOW:                         return "sampler1DShadow";
                case GL_SAMPLER_2D_SHADOW:                         return "sampler2DShadow";
                case GL_SAMPLER_1D_ARRAY:                          return "sampler1DArray";
                case GL_SAMPLER_2D_ARRAY:                          return "sampler2DArray";
                case GL_SAMPLER_1D_ARRAY_SHADOW:                   return "sampler1DArrayShadow";
                case GL_SAMPLER_2D_ARRAY_SHADOW:                   return "sampler2DArrayShadow";
                case GL_SAMPLER_2D_MULTISAMPLE:                    return "sampler2DMS";
                case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:              return "sampler2DMSArray";
                case GL_SAMPLER_CUBE_SHADOW:                       return "samplerCubeShadow";
                case GL_SAMPLER_BUFFER:                            return "samplerBuffer";
                case GL_SAMPLER_2D_RECT:                           return "sampler2DRect";
                case GL_SAMPLER_2D_RECT_SHADOW:                    return "sampler2DRectShadow";
                case GL_INT_SAMPLER_1D:                            return "isampler1D";
                case GL_INT_SAMPLER_2D:                            return "isampler2D";
                case GL_INT_SAMPLER_3D:                            return "isampler3D";
                case GL_INT_SAMPLER_CUBE:                          return "isamplerCube";
                case GL_INT_SAMPLER_1D_ARRAY:                      return "isampler1DArray";
                case GL_INT_SAMPLER_2D_ARRAY:                      return "isampler2DArray";
                case GL_INT_SAMPLER_2D_MULTISAMPLE:                return "isampler2DMS";
                case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:          return "isampler2DMSArray";
                case GL_INT_SAMPLER_BUFFER:                        return "isamplerBuffer";
                case GL_INT_SAMPLER_2D_RECT:                       return "isampler2DRect";
                case GL_UNSIGNED_INT_SAMPLER_1D:                   return "usampler1D";
                case GL_UNSIGNED_INT_SAMPLER_2D:                   return "usampler2D";
                case GL_UNSIGNED_INT_SAMPLER_3D:                   return "usampler3D";
                case GL_UNSIGNED_INT_SAMPLER_CUBE:                 return "usamplerCube";
                case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:             return "usampler2DArray";
                case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:             return "usampler2DArray";
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:       return "usampler2DMS";
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY: return "usampler2DMSArray";
                case GL_UNSIGNED_INT_SAMPLER_BUFFER:               return "usamplerBuffer";
                case GL_UNSIGNED_INT_SAMPLER_2D_RECT:              return "usampler2DRect";
                case GL_IMAGE_1D:                                  return "image1D";
                case GL_IMAGE_2D:                                  return "image2D";
                case GL_IMAGE_3D:                                  return "image3D";
                case GL_IMAGE_2D_RECT:                             return "image2DRect";
                case GL_IMAGE_CUBE:                                return "imageCube";
                case GL_IMAGE_BUFFER:                              return "imageBuffer";
                case GL_IMAGE_1D_ARRAY:                            return "image1DArray";
                case GL_IMAGE_2D_ARRAY:                            return "image2DArray";
                case GL_IMAGE_2D_MULTISAMPLE:                      return "image2DMS";
                case GL_IMAGE_2D_MULTISAMPLE_ARRAY:                return "image2DMSArray";
                case GL_INT_IMAGE_1D:                              return "iimage1D";
                case GL_INT_IMAGE_2D:                              return "iimage2D";
                case GL_INT_IMAGE_3D:                              return "iimage3D";
                case GL_INT_IMAGE_2D_RECT:                         return "iimage2DRect";
                case GL_INT_IMAGE_CUBE:                            return "iimageCube";
                case GL_INT_IMAGE_BUFFER:                          return "iimageBuffer";
                case GL_INT_IMAGE_1D_ARRAY:                        return "iimage1DArray";
                case GL_INT_IMAGE_2D_ARRAY:                        return "iimage2DArray";
                case GL_INT_IMAGE_2D_MULTISAMPLE:                  return "iimage2DMS";
                case GL_INT_IMAGE_2D_MULTISAMPLE_ARRAY:            return "iimage2DMSArray";
                case GL_UNSIGNED_INT_IMAGE_1D:                     return "uimage1D";
                case GL_UNSIGNED_INT_IMAGE_2D:                     return "uimage2D";
                case GL_UNSIGNED_INT_IMAGE_3D:                     return "uimage3D";
                case GL_UNSIGNED_INT_IMAGE_2D_RECT:                return "uimage2DRect";
                case GL_UNSIGNED_INT_IMAGE_CUBE:                   return "uimageCube";
                case GL_UNSIGNED_INT_IMAGE_BUFFER:                 return "uimageBuffer";
                case GL_UNSIGNED_INT_IMAGE_1D_ARRAY:               return "uimage1DArray";
                case GL_UNSIGNED_INT_IMAGE_2D_ARRAY:               return "uimage2DArray";
                case GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE:         return "uimage2DMS";
                case GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY:   return "uimage2DMSArray";
                case GL_UNSIGNED_INT_ATOMIC_COUNTER:               return "atomic_uint";
                default:
                    return "unknown";
            }
        }

        static string GLSLTypeNameArray(GLenum type, size_t multiplicity)
        {
            assert(multiplicity > 0);
            if (multiplicity == 1)
                return GLSLTypeName(type);
            else
                return format("%s[%s]", GLSLTypeName(type), multiplicity);
        }
    }
}

static assert(is(GLint == int));
static assert(is(GLuint == uint));
static assert(is(GLfloat == float));
static assert(is(GLdouble == double));
