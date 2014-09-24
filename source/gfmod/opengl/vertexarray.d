module gfmod.opengl.vertexarray;

import std.string;
import std.traits;
import std.typecons;
import std.typetuple;

import derelict.opengl3.gl3;

import gfmod.opengl.opengl;
import gfmod.opengl.program;

import gl3n.linalg;


/// Primitive types that may be stored in a VertexArray.
enum PrimitiveType: GLenum
{
    Points        = GL_POINTS,
    LineStrip     = GL_LINE_STRIP,
    LineLoop      = GL_LINE_LOOP,
    Lines         = GL_LINES,
    TriangleStrip = GL_TRIANGLE_STRIP,
    TriangleFan   = GL_TRIANGLE_FAN,
    Triangles     = GL_TRIANGLES
}


/// Possible types of a single element of a vertex attribute.
alias AttributeElementTypes = TypeTuple!(float, double, byte, short, int, ubyte, ushort, uint);

/// GL types corresponding to items in AttributeElementTypes.
enum attributeElementGLTypes = [GL_FLOAT, GL_DOUBLE, 
                                GL_BYTE, GL_SHORT, GL_INT,
                                GL_UNSIGNED_BYTE, GL_UNSIGNED_SHORT, GL_UNSIGNED_INT];

/// Determine if a type can be an attribute (aka field, aka property) of a vertex type.
template isVertexAttribute(A)
{
    // gl3n.linalg.Vector has vt (element type) and dimension.
    // We're not likely to accidentally hit another type with the same combination...
    // and if we do, it's probably someone intentionally making a compatible type.
    static if(hasMember!(A, "vt") && hasMember!(A, "dimension"))
    {
        enum isVertexAttribute = staticIndexOf!(A.vt, AttributeElementTypes) != -1 &&
                                 A.dimension >= 1 && A.dimension <= 4;
    }
    else
    {
        // Scalar types should work too.
        enum isVertexAttribute = staticIndexOf!(A, AttributeElementTypes) != -1;;
    }
}

/// Determine GL type of a vertex attribute.
template glType(A)
    if(isVertexAttribute!A)
{
    alias ElemType = Select!(hasMember!(A, "vt"), A.vt, A);
    enum glType = attributeElementGLTypes[staticIndexOf!(ElemType, AttributeElementTypes)];
}

/// Determine the dimensionality if a vertex attribute.
template dimension(A)
    if(isVertexAttribute!A)
{
    enum dimension = Select!(hasMember!(A, "dimension"), A.dimension, A);
}

//XXX the VertexArray type can be extended further:
//    Support multiple template args (not just 'V'). If there are multiple template args,
//    their attributes will be in separate VBOs. It will be then possible to add just
//    to those VBOs with add(), and to access just those VBOs memory buffers by data().
//
//    This way we can have both interleaved and separate VBOs, and anything in between.

/// Determine if a type is a valid vertex type.
///
/// A vertex type must be a plain-old-data struct with no custom
/// destructor/copyctor/assign and all its data members must be 1 to 4-dimensional
/// gl3n.linalg.Vectors such as vec3 or Vector!(4, ubyte).
enum isVertex(V) = is(V == struct) &&
                   !hasElaborateDestructor!V &&
                   !hasElaborateCopyConstructor!V &&
                   !hasElaborateAssign!V &&
                   allSatisfy!(isVertexAttribute, FieldTypeTuple!V);

// TODO: Currently, integral vertex attributes are automatically normalized into 
//       the 0-1 range. Add a @nonormalize UDA to be able to disable this 
//       (e.g. @nonormalize vec4ub thisIsNotAColor) 2014-08-14

/// A wrapper around GL Vertex Attribute Object that also manages its vertex storage.
///
/// Acts as a dynamic array of vertex type V. 
///
/// V must be a plain-old-data struct where each member is either a gl3n Vector
/// (such as vec3) or a scalar number (such as float).
/// 
/// Example vertex type:
///
/// --------------------
/// struct Vertex
/// {
///     vec3 position;
///     vec3 normal;
///     Vector!(ubyte, 4) rgbaColor;
/// }
/// --------------------
///
/// Vertex attributes must be either one of the following types: $(I float, double,
/// byte, short, int, ubyte, ushort, uint) or a 4 or less dimensional gl3n.linalg.Vector
/// with type parameter set to one of listed types. Note that by default, attributes
/// with integral values will have those values normalized into the [0-1] range (for
/// example, a color channel with value of 255 will be normalized into 1.0). In future,
/// an UDA (TODO) will be added to allow the user to disable normalization of integers.
///
/// The VertexArray requires a shader program when being bound and looks for vertex attributes
/// with names corresponding to fields of V. Any shader program used to draw a VertexArray must
/// contain vertex attributes for all members of V (otherwise VertexArray binding will fail).
///
/// For example, the following vertex shader source has all members specified by the
/// $(D Vertex) struct in the above example:
///
/// --------------------
/// #version 130
///
/// in vec3 position;
/// in vec3 normal;
/// in vec4 rgbaColor;
///
/// void main()
/// {
///     // ... do stuff here ...
/// }
/// --------------------
final class VertexArray(V)
    if(isVertex!V)
{
private:
    // The GL VAO handle.
    GLuint vao_;
    // Handle to the GL VBO used to store all vertex attributes.
    GLuint vbo_;

    // OpenGL info and logging.
    OpenGL gl_;

    // Storage for a RAM copy of VBO data.
    V[] storage_;
    // Used part of storage_.
    V[] vertices_;

    // Current state of the VertexArray.
    State state_ = State.Unlocked;

    // The program that was last used to draw data from the VertexArray.
    //
    // Needed to check if the user is changing programs (in which case we need to
    // reload vertex attributes from the program).
    GLProgram lastProgram_ = null;

    // True if _any_ VertexArray is bound. Used to avoid collisions between VAOs.
    static bool isAnyVAOBound_ = false;

    // We can, so why not?
    import std.range: isOutputRange;
    static assert(isOutputRange!(typeof(this), V), "VertexArray must be an OutputRange");

public:
    /// Possible states a VertexArray can be in.
    enum State
    {
        /// The VertexArray can be modified but not bound or drawn.
        Unlocked,
        /// The VertexArray can not be modified, but can be bound.
        Locked,
        /// The VertexArray can't be modified and can be drawn.
        Bound
    }

    /** Construct a VertexArray.
     *
     * Params:
     *
     * gl      = The OpenGL wrapper.
     * storage = Space to store vertices in (we need to store a copy of all vertex data
     *           in RAM to allow easy modification). Determines the maximum number of
     *           vertices the VertexArray can hold. The VertexArray $(B will not) 
     *           deallocate this space when destroyed; the caller must take care of that.
     */
    this(OpenGL gl, V[] storage) @trusted nothrow @nogc
    {
        gl_       = gl;
        storage_  = storage;
        vertices_ = storage_[0 .. 0];

        glGenBuffers(1, &vbo_);
        glGenVertexArrays(1, &vao_);
    }

    /** Destroy the VertexArray.
     *
     * Must be destroyed by the user to ensure all used GL objects are deleted.
     */
    ~this() @trusted nothrow @nogc
    {
        glDeleteVertexArrays(1, &vao_);
        glDeleteBuffers(1, &vbo_);
    }

    /** Add a vertex to the VertexArray.
     *
     * Must not add any more vertices if VertexArray.length == VertexArray.capacity.
     * Must not be called when the VertexArray is locked.
     */
    void put(const V vertex) @safe pure nothrow @nogc
    {
        assert(state_ == State.Unlocked, "Trying to add a vertex to a locked VertexArray");
        const length = vertices_.length;
        if(length >= storage_.length) { assert(false, "This VertexArray is already full"); }

        storage_[length] = vertex;
        vertices_ = storage_[0 .. length + 1];
    }

    /** Get direct access to vertices in the VertexArray.
     *
     * Can be used for fast modification of the VertexArray. Any modifications to the slice
     * after the VertexArray is locked will result in $(B undefined behavior).
     */
    V[] data() @system pure nothrow @nogc
    {
        assert(state_ == State.Unlocked,
               "Trying to get direct access to contents of a locked VertexArray");
        return vertices_;
    }

    /// Get the current number of vertices in the VertexArray.
    size_t length() @safe pure nothrow const @nogc
    {
        return vertices_.length;
    }

    /** Manually set the length of the VertexArray.
     *
     * Params:
     *
     * rhs = The new length of the VertexArray. Must be <= capacity. If used to increase the
     *       length, the new elements of the VertexArray ([oldLength .. newLength]) will have
     *       $(B uninitialized values).
     */
    void length(size_t rhs) @system pure nothrow @nogc
    {
        assert(state_ == State.Unlocked, "Trying to set length of a locked VertexArray");
        assert(rhs <= storage_.length, "Can't extend VertexArray length further than capacity");
        vertices_ = storage_[0 .. rhs];
    }

    /** Get the maximum number of vertices the VertexArray can hold.
     *
     * If VertexArray.length equals this value, no more vertices can be added.
     */
    size_t capacity() @safe pure nothrow const @nogc { return storage_.length; }

    /// Is the VertexArray empty (no vertices) ?
    bool empty() @safe pure nothrow const @nogc { return length == 0; }

    /** Clear the VertexArray, deleting all vertices.
     *
     * Can only be called while the VertexArray is unlocked.
     */
    void clear() @trusted pure nothrow @nogc { length = 0; }

    /** Draw vertices from the VertexArray directly, without using indices.
     *
     * This is the only way to draw if the VertexArray has no index type.
     *
     * Can only be called when the VertexArray is bound.
     *
     * Params:
     *
     * type  = Type of primitives to draw.
     * first = Index of the first vertex to draw.
     * count = Number of vertices to draw.
     *
     * first + count <= VertexArray.length() must be true.
     */
    void draw(PrimitiveType type, size_t first, size_t count)
        @trusted nothrow @nogc
    {
        assert(state_ == State.Bound, "Trying to draw a VertexArray that is not bound");
        assert(first + count <= length, "VertexArray draw call out of range.");
        glDrawArrays(cast(GLenum)type, cast(int)first, cast(int)count);
    }

    /** Lock the buffer.
     *
     * Must be called before binding the buffer for drawing.
     *
     * It is a good practice to keep a buffer locked for a long time.
     */
    void lock() @trusted nothrow @nogc
    {
        assert(state_ == State.Unlocked, "Trying to lock a VertexArray that's already locked");

        // Ensure that if anything is bound, it stays bound when we're done.
        GLint oldBound;
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING,  &oldBound);
        scope(exit) { glBindBuffer(GL_ARRAY_BUFFER, oldBound); }

        glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        glBufferData(GL_ARRAY_BUFFER, vertices_.length * V.sizeof, vertices_.ptr,
                     GL_STATIC_DRAW);

        state_ = State.Locked;
    }

    /** Unlock the buffer.
     *
     * Must be called before modifying the buffer if it was locked previously.
     */
    void unlock() @safe pure nothrow @nogc 
    {
        assert(state_ == State.Locked,
               "Trying to unlock a buffer that is either bound or not locked");
        state_ = State.Unlocked;
    }

    /** Bind the VertexArray for drawing. Must be called before drawing. VertexArray
     *  must be locked.
     *
     * Only one VertexArray can be bound at a time. It must be released before binding another
     * VertexArray.
     *
     * Params:
     *
     * program = The vertex program that will be used to draw data from this VertexArray.
     *           Needed for the VertexArray to specify which data corresponds to which
     *           attributes.
     *
     * Returns: true on success, false on failure (not all vertex attributes found in
     *          the program).
     */
    bool bind(GLProgram program) @trusted nothrow @nogc
    {
        assert(state_ == State.Locked,
               "Trying to bind a VertexArray that is either already bound or not locked");

        // TODO: Once moved to newer than GL 3.0, remove isAnyVAOBound and use
        // glGetIntegerv(GL_VERTEX_ARRAY_BINDING) to ensure nothing else is bound
        // at the moment 2014-08-12
        assert(!isAnyVAOBound_, "Another VertexArray is bound already");

        if(program !is lastProgram_)
        {
            import tharsis.util.traits: FieldNamesTuple;
            alias fieldNames = FieldNamesTuple!V;

            // Need to check if we have all attribs before we start messing with the
            // VAO.
            foreach(name; fieldNames) if(!program.hasAttrib(name))
            {
                return false;
            }

            glBindVertexArray(vao_);
            glBindBuffer(GL_ARRAY_BUFFER, vbo_);

            // Tell the VAO where in the VBO data for each vertex attrib is.
            enum int stride = V.sizeof;
            size_t offset = 0;
            foreach(index, Attrib; FieldTypeTuple!V)
            {
                enum name    = fieldNames[index];
                const attrib = program.attrib(name);
                glEnableVertexAttribArray(attrib.location);
                glVertexAttribPointer(attrib.location,
                                      dimension!Attrib,
                                      glType!Attrib,
                                      isIntegral!(Attrib.vt) ? GL_TRUE : GL_FALSE,
                                      stride, 
                                      cast(void*)offset);
                offset += Attrib.sizeof;
            }
            glBindVertexArray(0);
            // Rebind, just to be sure.
            glBindBuffer(GL_ARRAY_BUFFER, 0);
            lastProgram_ = program;
        }

        glBindVertexArray(vao_);

        isAnyVAOBound_ = true;
        state_         = State.Bound;
        return true;
    }

    /** Release the buffer after drawing.
     *
     * Must be called before making any modifications to the buffer.
     */
    void release() @trusted nothrow @nogc
    {
        assert(state_ == State.Bound, "Trying to release a VertexArray that is not bound");

        glBindVertexArray(0);
        state_         = State.Locked;
        isAnyVAOBound_ = false;
    }
}
