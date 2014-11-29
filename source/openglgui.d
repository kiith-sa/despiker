//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Default (and at the moment, only) Despiker GUI, based on SDL and OpenGL, using dimgui.
module openglgui;

import std.algorithm: find, map, max, min;
import std.exception: enforce, assumeWontThrow;
import std.experimental.logger;
import std.math: pow;
import std.string: format;

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

/// Default (and at the moment, only) Despiker GUI, based on SDL and OpenGL, using dimgui.
class OpenGLGUI: DespikerGUI
{
private:
    // Video device used to access window size, do manual rendering, etc.
    VideoDevice video_;
    // Access to input.
    InputDevice input_;

    // Main log.
    Logger log_;

    // Despiker implementation.
    Despiker despiker_;

    // GUI layout.
    Layout layout_;

    // Renders the viewed zone graphs.
    ViewRenderer view_;

    // Current positions of scroll area scrollbars.
    int sidebarScroll, sideinfoScroll;

    // Buffer to store goToFrame_ text input.
    char[9] goToFrameBuf_;
    // Entered text of the 'Go to Frame' text input.
    char[] goToFrame_;

    // Used to override default imgui color scheme. Currently only passed to scroll areas.
    ColorScheme guiScheme_;

    // Current zoom exponent. Mouse wheel and the -/= keys affect this.
    //
    // 0 means no zoom. The actual zoom is 1.25 ^ zoomExponent_.
    int zoomExponent_ = 0;

    // Panning value. RMB dragging and A/D keys affect this.
    //
    // Higher means the view is shifted to the left; lower to the right.
    // Independent of zoom; the same value of pan_ will result on the view being centered
    // at the same location regardless of zoom.
    double pan_ = 0;

public:
    /** Construct the GUI.
     *
     * Params:
     *
     * log      = Main program log.
     * despiker = Despiker implementation.
     */
    this(Logger log, Despiker despiker) @trusted
    {
        log_      = log;
        despiker_ = despiker;
        layout_   = new Layout();

        // Init Derelict and SDL.
        enum baseMsg = "Failed to initialize GUI: failed to";
        enforce(loadDerelict(log_), new GUIException(baseMsg ~ "load Derelict"));
        scope(failure) { unloadDerelict(); }
        enforce(initSDL(log_), new GUIException(baseMsg ~ "initialize SDL"));
        scope(failure) { deinitSDL(); }

        // Init video and input.
        video_ = new VideoDevice(log_);
        scope(failure) { destroy(video_); }
        enforce(initVideo(video_, log_), new GUIException(baseMsg ~ "initialize VideoDevice"));
        input_ = new InputDevice(&video_.height, log_);
        scope(failure) { destroy(input_); }

        // Prepare GL state for GUI drawing.
        glClearColor(0.25f, 0.25f, 0.25f, 0.25f);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_DEPTH_TEST);

        // We only override the scroll area color scheme (to remove transparency).
        guiScheme_ = defaultColorScheme;
        guiScheme_.scroll.area.back = RGBA(32, 32, 32, 255);

        goToFrame_ = goToFrameBuf_[0 .. 0];

        view_ = new ViewRenderer(video_, log_, layout_);
        scope(failure) { destroy(view_); }

        enforce(imguiInit(findFont(), 512), new GUIException(baseMsg ~ "initialize imgui"));
        scope(failure) { imguiDestroy(); }
    }

    /// Destroy the GUI. Must be called to properly free GL resources.
    ~this() @trusted
    {
        imguiDestroy();
        destroy(view_);
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
            // Get keyboard/mouse input.
            input_.update();
            if(input_.quit) { break; }
            // React to window resize events.
            if(input_.resized)
            {
                video_.resizeViewport(input_.resized.width, input_.resized.height);
            }

            // Update the Despiker.
            despiker_.update();
            // Update the GUI.
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
    void update() @system nothrow
    {
        // Clear the screen.
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Get mouse input and pass it to imgui.
        const mouse = input_.mouse;
        ubyte mouseButtons;
        if(mouse.button(Mouse.Button.Left))  { mouseButtons |= MouseButton.left; }
        if(mouse.button(Mouse.Button.Right)) { mouseButtons |= MouseButton.right; }

        const int width  = cast(int)video_.width;
        const int height = cast(int)video_.height;

        // Start drawing the GUI.
        imguiBeginFrame(mouse.x, mouse.y, mouseButtons, mouse.wheelYMovement, input_.unicode)
                       .assumeWontThrow;
        scope(exit)
        {
            imguiEndFrame().assumeWontThrow;
            imguiRender(width, height).assumeWontThrow;
        }
        layout_.update(width, height);

        import std.array: empty;
        const view   = despiker_.view;
        const noView = view.empty;

        if(!noView)
        {
            // Get the real start/end time of the frame containing execution in all threads.
            const start = view.map!(v => v[0].startTime).reduce!min.assumeWontThrow;
            const end   = view.map!(v => v[0].endTime).reduce!max.assumeWontThrow;
            const duration = end - start;

            // Get input for the ViewRenderer (zooming, panning).
            getViewInput();
            // Draw the view first so any widgets are on top of it.
            view_.startDrawing(zoom, pan_, start, duration);
            foreach(ref threadView; view) { view_.drawThread(threadView[1].save); }
            view_.endDrawing();

            infoSidebar(start, duration).assumeWontThrow;
        }

        // Sidebars rendering and input.
        actionsSidebar().assumeWontThrow();
    }

    /// Get input for the view renderer (zooming and panning).
    void getViewInput() @safe pure nothrow @nogc
    {
        const kb    = input_.keyboard;
        const mouse = input_.mouse;

        // Zooming ('=' is the same key as '+' on most (at least QWERTY) keyboards).
        const zoomKb = (kb.pressed(Key.Equals) ? 1 : 0) + (kb.pressed(Key.Minus) ? -1 : 0);
        zoomExponent_ = min(40, max(-8, zoomExponent_ + mouse.wheelYMovement + zoomKb));
        // Panning
        pan_ -= 128 * ((kb.pressed(Key.D) ? 1 : 0) + (kb.pressed(Key.A) ? -1 : 0)) / zoom;
        if(mouse.button(Mouse.Button.Right)) { pan_ += mouse.xMovement / zoom; }
    }

    /** Render (and handle input from) the actions sidebar.
     *
     * While not nothrow, actionsSidebar() should be assumed to never throw.
     */
    void actionsSidebar() @trusted
    {
        // The actions sidebar.
        with(layout_)
        {
            imguiBeginScrollArea("Actions", sidebarX, sidebarY, sidebarW, sidebarH,
                                 &sidebarScroll, guiScheme_);
        }
        scope(exit) { imguiEndScrollArea(); }

        // Draws a button with a key shortcut to do the same action.
        auto button = (string text, Key key) =>
                      imguiButton(text) || input_.keyboard.pressed(key);
        final switch(despiker_.mode)
        {
            case Despiker.Mode.NewestFrame:
                if(button("Pause <Space>",   Key.Space)) { despiker_.pause(); }
                if(button("Worst Frame <1>", Key.One))   { despiker_.worstFrame(); }
                break;
            case Despiker.Mode.Manual:
                if(button("Resume <Space>",     Key.Space)) { despiker_.resume(); }
                if(button("Next Frame <L>",     Key.L))     { despiker_.nextFrame(); }
                if(button("Previous Frame <H>", Key.H))     { despiker_.previousFrame(); }
                if(button("Worst Frame <1>",    Key.One))   { despiker_.worstFrame(); }
                try if(imguiTextInput("Jump", goToFrameBuf_, goToFrame_))
                {
                    import std.conv;
                    scope(exit) { goToFrame_ = goToFrameBuf_[0 .. 0]; }
                    despiker_.frame = to!size_t(goToFrame_);
                }
                catch(Exception e)
                {
                    log_.info("Invalid 'Go to Frame' input from user (expected "
                              "number, got " ~ goToFrame_);
                }
                break;
        }
    }

    /** Render the info sidebar.
     *
     * Params:
     *
     * start    = Start time of the currently viewed frame.
     * duration = Duration of the currently viewed frame.
     *
     * While not nothrow, infoSidebar() should be assumed to never throw.
     */
    void infoSidebar(ulong start, ulong duration) @trusted
    {
        // The info sidebar.
        with(layout_)
        {
            imguiBeginScrollArea("Info", sideinfoX, sideinfoY, sideinfoW, sideinfoH,
                                 &sideinfoScroll, guiScheme_);
        }
        scope(exit) { imguiEndScrollArea(); }

        const frame = despiker_.frame;
        const noFrame = frame == size_t.max;

        imguiLabel("Frame: " ~ (noFrame ? "N/A" : "%s".format(frame)));
        imguiLabel("Duration: " ~ (noFrame ? "N/A" : "%.2fms".format(duration * 0.0001)));
        imguiLabel("Start: " ~ (noFrame ? "N/A" : "%.5fs".format(start * 0.0000001)));
        imguiLabel("Frames: %s".format(despiker_.frameCount));
    }

    /// Get the current zoom ratio (not exponent).
    double zoom() @safe pure nothrow const @nogc
    {
        return pow(1.25, zoomExponent_);
    }

    import derelict.sdl2.sdl;
    /** Find the font file to use for text drawing and return its filename.
     *
     * Throws: GUIException on failure.
     */
    static string findFont() @trusted
    {
        import std.file: thisExePath, exists, isFile;
        import std.path: dirName, buildPath;

        string[] fontDirs = [thisExePath().dirName()];
        // For (eventual) root Despiker installations.
        version(linux) { fontDirs ~= "/usr/share/despiker"; }

        // Find the font in fontDirs.
        enum fontName = "DroidSans.ttf";
        auto found = fontDirs.map!(dir => dir.buildPath(fontName))
                             .find!(p => p.exists && p.isFile);
        if(!found.empty) { return found.front; }
        foreach(path; fontDirs.map!(dir => dir.buildPath(fontName)))
        {
            if(path.exists && path.isFile) { return path; }
        }

        throw new GUIException("Despiker font %s not found in any of expected directories: %s"
                               .format(fontName, fontDirs));
    }

    /// Load libraries using through Derelict (currently, this is SDL2).
    static bool loadDerelict(Logger log) @system nothrow
    {
        import derelict.util.exception;
        // Load (but don't init) SDL2.
        try
        {
            DerelictSDL2.load();
            return true;
        }
        catch(SharedLibLoadException e)
        {
            log.critical("SDL2 not found: ", e.msg).assumeWontThrow;
        }
        catch(SymbolLoadException e)
        {
            log.critical("Missing SDL2 symbol (old SDL2 version?): ", e.msg).assumeWontThrow;
        }
        catch(Exception e)
        {
            assert(false, "Unexpected exception in DerelictSDL2.load()");
        }

        return false;
    }

    /// Unload Derelict libraries.
    static void unloadDerelict() @system nothrow
    {
        DerelictSDL2.unload().assumeWontThrow;
    }

    /// Initialize the SDL library.
    static bool initSDL(Logger log) @system nothrow
    {
        // Initialize SDL Video subsystem.
        if(SDL_Init(SDL_INIT_VIDEO) < 0)
        {
            // SDL_Init returns a negative number on error.
            log.critical("SDL Video subsystem failed to initialize").assumeWontThrow;
            return false;
        }
        return true;
    }

    /// Deinitialize the SDL library.
    static void deinitSDL() @system nothrow @nogc
    {
        SDL_Quit();
    }

    /// Initialize the video device (setting video mode and initializing OpenGL).
    static bool initVideo(VideoDevice video_, Logger log) @system nothrow
    {
        // Initialize the video device.
        const width        = 1024;
        const height       = 768;
        import std.typecons;
        const fullscreen   = No.fullscreen;

        if(!video_.initWindow(width, height, fullscreen)) { return false; }
        if(!video_.initGL()) { return false; }
        video_.windowTitle = "Despiker";
        return true;
    }
}


private:

/// GUI layout.
class Layout
{
    // Margin between GUI elements.
    int margin = 4;

    // Size and position of the sidebar.
    int sidebarW, sidebarH, sidebarX, sidebarY;

    // Size and position of the 'info' sidebar.
    int sideinfoW, sideinfoH, sideinfoX, sideinfoY;

    // Size and position of the view.
    int viewW, viewH, viewX, viewY;

    /** Update the layout.
     *
     * Called at the beginning of a GUI update.
     *
     * Params:
     *
     * width  = Window width.
     * height = Window height.
     *
     */
    void update(int width, int height) @safe pure nothrow @nogc
    {
        // max() avoids impossibly small areas when the window is very small.

        sidebarW = max(20, min(192, cast(int)(width.pow(0.75))));
        sidebarH = max(20, (height - 3 * margin) / 2);
        sidebarY = max(20, margin * 2 + sidebarH);
        sidebarX = max(20, width - sidebarW - margin);

        sideinfoW = sidebarW;
        sideinfoH = sidebarH;
        sideinfoX = sidebarX;
        sideinfoY = margin;

        viewX = margin;
        viewY = margin;
        viewW = max(20, width - sidebarW - 2 * margin - viewX);
        viewH = max(20, height - 2 * margin);
    }
}


import gl3n_extra.linalg;
/// Simple 2D camera (used for the view area).
final class Camera
{
private:
    // Pushing/popping camera state can be added when needed since we use MatrixStack
    import gfmod.opengl.matrixstack;

    // Projection matrix stack.
    MatrixStack!(float, 4) projectionStack_;

    // 2D extents of the camera. Signed to avoid issues with negative values.
    long width_, height_;
    // Center of the camera (the point the camera is looking at in 2D space).
    vec2 center_;

public:
@safe pure nothrow:
    /** Construct a Camera with window size.
     *
     * Params:
     *
     * width  = Camera width in pixels.
     * height = Camera height in pixels.
     */
    this(size_t width, size_t height)
    {
        width_  = width;
        height_ = height;
        center_ = vec2(0.0f, 0.0f);
        projectionStack_ = new MatrixStack!(float, 4)();
        updateProjection();
    }

@nogc:
    /// Get the current projection matrix.
    mat4 projection() const { return projectionStack_.top; }

    /// Set the center of the camera (the point the camera is looking at).
    void center(const vec2 rhs)
    {
        center_ = rhs;
        updateProjection();
    }

    /// Set camera size in pixels. Both width and height must be greater than zero.
    void size(size_t width, size_t height)
    {
        assert(width > 0 && height > 0, "Can't have camera width/height of 0");
        width_  = width;
        height_ = height;
        updateProjection();
    }

private:
    /// Update the orthographic projection matrix.
    void updateProjection()
    {
        const hWidth  = max(width_  * 0.5f, 1.0f);
        const hHeight = max(height_ * 0.5f, 1.0f);
        projectionStack_.loadIdentity();
        projectionStack_.ortho(center_.x - hWidth, center_.x + hWidth,
                               center_.y - hHeight, center_.y + hHeight, -8000, 8000);
    }
}


/// Renders the zone graph view.
class ViewRenderer
{
private:
    // Video device used to access window size, do manual rendering, etc.
    VideoDevice video_;

    // Main log.
    Logger log_;

    // GUI layout.
    Layout layout_;


    import gl3n_extra.color;
    // A simple 2D vertex.
    struct Vertex
    {
        vec2 position;
        Color color;
    }

    // Source of the shader used for drawing.
    enum shaderSrc =
      q{#version 130
        #if VERTEX_SHADER
            uniform mat4 projection;
            in vec2 position;
            in vec4 color;
            smooth out vec4 fsColor;

            void main()
            {
                gl_Position = projection * vec4(position, 0.0, 1.0);
                fsColor = color;
            }
        #elif FRAGMENT_SHADER
            smooth in vec4 fsColor;
            out vec4 resultColor;

            void main() { resultColor = fsColor; }
        #endif
       };

    import gfmod.opengl;
    // OpenGL wrapper.
    OpenGL gl_;

    /* GLSL program used for drawing, compiled from shaderSrc.
     *
     * If null (failed to compile), nothing is drawn.
     */
    GLProgram program_;

    // Specification of uniform variables that should be in program_.
    struct UniformsSpec
    {
        mat4 projection;
    }

    import gfmod.opengl.uniform;
    // Provides access to uniform variables in program_.
    GLUniforms!UniformsSpec uniforms_;

    // Triangles in the zone graph (used for zone rectangles).
    VertexArray!Vertex trisBatch_;
    // Lines in the zone graph (used for dividing lines between rectangles).
    VertexArray!Vertex linesBatch_;
    // View area border.
    VertexArray!Vertex border_;

    // Base colors for zone rectangles.
    static immutable Color[16] baseColors =
        [rgb!"FF0000", rgb!"00FF00", rgb!"6060FF", rgb!"FFFF00",
         rgb!"FF00FF", rgb!"00FFFF", rgb!"FF8000", rgb!"80FF00",

         rgb!"FF0080", rgb!"8000FF", rgb!"00FF80", rgb!"80FF00",
         rgb!"800000", rgb!"008000", rgb!"606080", rgb!"808000"];


    // 2D camera used to build the projection matrix. Not used for zoom/panning.
    Camera camera_;

    // Current state of the ViewRenderer.
    enum State
    {
        NotDrawing,
        Drawing
    }

    // Current state of the ViewRenderer.
    State state_ = State.NotDrawing;

    // Minimum and maximum height of a nesting level (zone + gap above it).
    enum minNestLevelHeight = 8; enum maxNestLevelHeight = 24;

    // Y offset of zones in currently drawn thread. Increases between drawThread() calls.
    uint yOffset_;

    // Horizontal panning of the view (passed to startDrawing()).
    double pan_;
    // Horizontal zoom of the view (passed to startDrawing()). Higher means closer.
    double zoom_;

    // Start time of the currently drawn frame (passed to startDrawing()).
    ulong frameStartTime_;
    // Duration of the currently drawn frame (passed to startDrawing()).
    ulong frameDuration_;

public:
    /** Construct the view renderer.
     *
     * Params:
     *
     * video  = Video device used for drawing.
     * log    = Main log.
     * layout = GUI layout used for extents of the view.
     */
    this(VideoDevice video, Logger log, Layout layout) @safe nothrow
    {
        video_  = video;
        log_    = log;
        layout_ = layout;
        camera_ = new Camera(layout_.viewW, layout_.viewH);
        gl_     = video_.gl;

        // Try to initialize the GL program. On failure, we will set program_ to null and
        // do nothing in drawing functions.
        try
        {
            program_ = new GLProgram(gl_, shaderSrc);
            uniforms_ = GLUniforms!UniformsSpec(program_);
        }
        catch(OpenGLException e)
        {
            log_.error("Failed to construct zone view GLSL program or to load uniforms "
                       "from the program. Zone view will not be drawn.").assumeWontThrow;
            log_.error(e).assumeWontThrow;
            program_ = null;
        }
        catch(Exception e)
        {
            log_.error(e).assumeWontThrow;
            assert(false, "Unexpected exception in ViewRenderer.this()");
        }

        trisBatch_  = new VertexArray!Vertex(gl_, new Vertex[32768]);
        linesBatch_ = new VertexArray!Vertex(gl_, new Vertex[16384]);
        border_         = new VertexArray!Vertex(gl_, new Vertex[8]);
    }

    /// Destroy the view renderer. Must be called manually.
    ~this()
    {
        // Null if program initialization failed.
        if(program_ !is null) { destroy(program_); }
        destroy(border_);
        destroy(linesBatch_);
        destroy(trisBatch_);
    }

    /** Start drawing in a new frame.
     *
     * Params:
     *
     * zoom      = Horizontal zoom.
     * pan       = Horizontal panning.
     * startTime = Start time of the frame in hnsecs.
     * duration  = Duration of the frame in hnsecs.
     */
    void startDrawing(double zoom, double pan, ulong startTime, ulong duration)
        @trusted nothrow
    {
        if(program_ is null) { return; }
        scope(exit) { gl_.runtimeCheck(); }

        assert(zoom > 0.0, "Zoom must be greater than 0");
        assert(state_ == State.NotDrawing, "Called startTime() twice");
        state_ = State.Drawing;

        zoom_           = zoom;
        pan_            = pan;
        frameStartTime_ = startTime;
        frameDuration_  = duration;

        const w  = video_.width;
        const h  = video_.height;
        const lx = layout_.viewX;
        const ly = layout_.viewY;
        const lw = layout_.viewW;
        const lh = layout_.viewH;

        camera_.size(cast(uint)w, cast(uint)h);
        // Align the camera with the view (so 0,0 is the bottom-left corner of the view).
        camera_.center = vec2(w / 2 - lx, h / 2 - ly);
        uniforms_.projection = camera_.projection;

        // Cut off parts of draws outside of the view area.
        glEnable(GL_SCISSOR_TEST);
        glScissor(lx, ly, lw, lh);


        // A thin black border around the view area (mainly to see the view is correct).
        vec2[8] borderLines = [vec2(1,  0),      vec2(1,  lh - 1),
                               vec2(1,  lh - 1), vec2(lw, lh - 1),
                               vec2(lw, lh - 1), vec2(lw, 0),
                               vec2(lw, 0),      vec2(1,  0)];
        foreach(v; borderLines) { border_.put(Vertex(v, rgba!"000000FF")); }
        drawBatch(border_, PrimitiveType.Lines);

        // Reset the y offset for zone draws.
        yOffset_ = 0;
    }

    import std.range: isInputRange, ElementType;
    import tharsis.prof;

    /** Draw zones executed during current frame in one thread.
     *
     * Must be called between startDrawing() and endDrawing(). The first drawThread call draws
     * zones from thread 0, the second from thread 1, etc.
     *
     * Params:
     *
     * zones = Zone range of all zones executed during the frame in the thread.
     */
    void drawThread(ZRange)(ZRange zones) @safe nothrow
        if(isInputRange!ZRange && is(ElementType!ZRange == ZoneData))
    {
        assert(state_ == State.Drawing, "drawThread() called without calling startDrawing()");

        uint maxNestLevel = 0;
        foreach(zone; zones)
        {
            maxNestLevel = max(zone.nestLevel, maxNestLevel);
            drawZone(zone);
        }

        yOffset_ += 8 + (maxNestLevel + 1) * nestLevelHeight;
    }

    /// End drawing a frame.
    void endDrawing() @trusted nothrow
    {
        if(program_ is null) { return; }

        assert(state_ == State.Drawing, "endDrawing() called twice or without startDrawing()");
        state_ = State.NotDrawing;
        scope(exit) { gl_.runtimeCheck(); }

        if(!trisBatch_.empty)  { drawBatch(trisBatch_, PrimitiveType.Triangles); }
        if(!linesBatch_.empty) { drawBatch(linesBatch_, PrimitiveType.Lines); }
        // Ensure any following draws aren't cut off by the scissor.
        glDisable(GL_SCISSOR_TEST);
    }

private:
    /// Get the height (in pixels) of a zone nest level (zone height + gap above it).
    uint nestLevelHeight() @safe pure nothrow const @nogc
    {
        return max(minNestLevelHeight, min(maxNestLevelHeight, layout_.viewH / 32));
    }

    /** Draw one zone (called by drawThread).
     *
     * Params:
     *
     * zone = Zone to draw.
     */
    void drawZone(ref const ZoneData zone) @trusted nothrow
    {
        const layoutW = layout_.viewW;

        const double frameDurationF    = cast(double)frameDuration_;
        const double relativeStartTime = zone.startTime - frameStartTime_;

        // Zooms X coordinates around the center of the view.
        double zoomX(double x) @safe nothrow @nogc
        {
            const center = layoutW / 2;
            return center + (pan_ + x - center) * zoom_;
        }

        const double minXNoZoom = (relativeStartTime / frameDurationF) * layoutW;
        // Zone rectangle coordinates. Using doubles to avoid some precision issues.
        const double minX = zoomX(minXNoZoom);
        const double maxX = zoomX(minXNoZoom + (zone.duration / frameDurationF) * layoutW);
        const double minY = yOffset_ + (zone.nestLevel - 1) * nestLevelHeight;
        const double maxY = minY + nestLevelHeight - 2;

        // Don't draw zones that would end up being too small (<=1px) on the screen
        if(maxX - minX <= 1.0) { return; }

        // Zone rectangle that will be drawn (2 triangles).
        vec2[6] rect = [vec2(minX, minY), vec2(maxX, maxY), vec2(minX, maxY),
                        vec2(minX, minY), vec2(maxX, minY), vec2(maxX, maxY)];
        // Lines on the sides of the rectangle (to separate it from other zones).
        vec2[4] lines = [rect[0], rect[2], rect[4], rect[1]];

        // Draw and empty any batches that are out of space.
        if(trisBatch_.capacity - trisBatch_.length < rect.length)
        {
            drawBatch(trisBatch_, PrimitiveType.Triangles);
        }
        if(linesBatch_.capacity - linesBatch_.length < lines.length)
        {
            drawBatch(linesBatch_, PrimitiveType.Lines);
        }

        const color = zoneColor(zone);
        // Darker color for lines
        const dark = Color(ubyte(color.r / 2), ubyte(color.g / 2), ubyte(color.b / 2),
                           ubyte(255));

        // Add the triangles/lines to batches.
        foreach(v; rect)  { trisBatch_.put(Vertex(v, color)); }
        foreach(v; lines) { linesBatch_.put(Vertex(v, dark)); }

        // This is drawn by imgui and is not affected by our camera, so we need to
        // position this manually.
        drawZoneText(zone, maxX - minX, 
                     layout_.viewX + (minX + maxX) / 2,
                     layout_.viewY + (minY + maxY) / 2 - 4);
    }

    /** Draw text on a zone rectangle.
     *
     * Params:
     *
     * zone      = Zone being drawn.
     * zoneWidth = Width of the zone rectangle.
     * centerX   = X center of the zone rectangle.
     * centerY   = Y center of the zone rectangle.
     */
    void drawZoneText(ref const ZoneData zone, double zoneWidth, double centerX, double centerY)
        @system nothrow
    {
        // May change or even be dynamic if we have different font sizes in future.
        enum charWidthPx = 9;
        const space = cast(int)(zoneWidth / charWidthPx);
        // Smallest strings returned by labelText() are 3 chars long or empty. No point
        // drawing if we can't fit 3 chars.
        if(space < 3) { return; }

        const label = labelText(space, zone);
        const long textWidthEst = charWidthPx * label.length;
        // Don't draw if outside the view area.
        if(centerX < 0 - textWidthEst || centerX > layout_.viewX + layout_.viewW + textWidthEst)
        {
            return;
        }

        imguiDrawText(cast(int)(centerX), cast(int)(centerY), TextAlign.center, label)
                     .assumeWontThrow;
    }

    /** Generate text for a zone label.
     *
     * Intelligently shortens the text if we can't fit everything into the zone rectangle.
     * Params:
     *
     * space = Number of characters we can fit onto the zone rectangle.
     * zone  = Zone being drawn.
     */
    string labelText(int space, ref const ZoneData zone) @system nothrow
    {
        const durMs = zone.duration * 0.0001;
        const durPc = zone.duration / cast(double)frameDuration_ * 100.0;

        string label;
        const needed = zone.info.length + ": 0.00ms, 00.00%".length;
        const info = zone.info;

        return ()
        {
            // Enough space; show everything.
            if(space >= needed)     { return "%s: %.2fms, %.1f%%".format(info, durMs, durPc); }
            // Remove spaces and decimal point from percentage time.
            if(needed - space <= 4) { return "%s:%.2fms|%.0f%%".format(info, durMs, durPc); }
            // Remove percentage time.
            if(needed - space <= 7) { return "%s:%.2fms".format(info, durMs); }

            // Shorten the info string while still displaying milliseconds.
            const infoSpace = max(0, space - cast(int)":0.00ms".length);
            const infoCut = info[0 .. min(infoSpace, info.length)];
            if(infoSpace > 0) { return "%s:%.2fms".format(infoCut, durMs); }

            // Just milliseconds.
            if(space >= "0.00ms".length) { return "%.2fms".format(durMs); }
            // Just milliseconds without the 'ms'.
            if(space >= "0.00".length)   { return "%.2f".format(durMs); }
            // Just milliseconds with only single decimal point precision.
            if(space >= "0.0".length)    { return "%.1f".format(durMs); }
            // Not enough space for anything.
            return "";
        }().assumeWontThrow;
    }

    /** Generate the color to draw specified zone with.
     *
     * The same zone should always have the same color, even between frames.
     */
    Color zoneColor(ref const ZoneData zone) @safe nothrow
    {
        // Using a hash of zone info ensures the same zone always has the same color.
        union HashBytes
        {
            ulong hash;
            ubyte[8] bytes;
        }
        HashBytes hash;
        hash.hash = typeid(zone.info).getHash(&zone.info);

        // Get a base color and slightly tweak it based on the hash.
        const base = baseColors[hash.bytes[3] % baseColors.length];
        auto mix = (uint i) => cast(ubyte)max(0, base.vector[i] - 32 + (hash.bytes[i] >> 3));
        return Color(mix(0), mix(1), mix(2), ubyte(255));
    }

    /// Draw all primitives in a batch and empty the batch.
    void drawBatch(VertexArray!Vertex batch, PrimitiveType type) @safe nothrow
    {
        scope(exit) { gl_.runtimeCheck(); }

        program_.use();
        scope(exit) { program_.unuse(); }

        batch.lock();
        scope(exit)
        {
            batch.unlock();
            batch.clear();
        }

        if(!batch.bind(program_))
        {
            log_.error("Failed to bind VertexArray \"%s\"; probably missing vertex "
                       " attribute in a GLSL program. Will not draw.").assumeWontThrow;
            return;
        }

        batch.draw(type, 0, batch.length);
        batch.release();
    }
}
