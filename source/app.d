import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio : writeln, writefln;
import std.string;

import deimos.glfw.glfw3;

import glad.gl.enums;
import glad.gl.ext;
import glad.gl.funcs;
import glad.gl.loader;
import glad.gl.types;

import glwtf.input;
import glwtf.window;

import imgui;

import window;


struct GUI
{
    this(Window window)
    {
        this.window = window;

        window.on_scroll.strongConnect(&onScroll);

        int width, height;
        glfwGetWindowSize(window.window, &width, &height);
        // trigger initial viewport transform.
        onWindowResize(width, height);

        window.on_resize.strongConnect(&onWindowResize);

        extern(C) static void getUnicode(GLFWwindow* w, uint unicode)
        {
            staticUnicode = unicode;
        }
        extern(C) static void getKey(GLFWwindow* w, int key, int scancode, int action, int mods)
        {
            if(action != GLFW_PRESS) { return; }
            if(key == GLFW_KEY_ENTER)          { staticUnicode = 0x0D; }
            else if(key == GLFW_KEY_BACKSPACE) { staticUnicode = 0x08; }
        }
        glfwSetCharCallback(window.window, &getUnicode);
        glfwSetKeyCallback(window.window, &getKey);
    }

    void render()
    {
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        // Mouse states
        ubyte mousebutton = 0;
        double mouseX, mouseY;
        glfwGetCursorPos(window.window, &mouseX, &mouseY);
        mouseY = windowHeight - mouseY;

        int leftButton   = glfwGetMouseButton(window.window, GLFW_MOUSE_BUTTON_LEFT);
        int rightButton  = glfwGetMouseButton(window.window, GLFW_MOUSE_BUTTON_RIGHT);
        int middleButton = glfwGetMouseButton(window.window, GLFW_MOUSE_BUTTON_MIDDLE);
        if (leftButton == GLFW_PRESS) { mousebutton |= MouseButton.left; }

        imguiBeginFrame(cast(int)mouseX, cast(int)mouseY,
                        mousebutton, mouseScroll, staticUnicode);
        staticUnicode = 0;
        if (mouseScroll != 0) { mouseScroll = 0; }


        import std.math: pow;
        const int margin   = 4;
        const int sidebarW = max(40, cast(int)(windowWidth.pow(0.75)));
        const int sidebarH = max(40, windowHeight - 2 * margin);
        const int sidebarX = max(40, windowWidth - sidebarW - margin);

        // The "Actions" sidebar
        {
            imguiBeginScrollArea("Actions",
                                 sidebarX, margin, sidebarW, sidebarH, &sidebarScroll);
            scope(exit) { imguiEndScrollArea(); }
        }

        imguiEndFrame();
        imguiRender(windowWidth, windowHeight);
    }

    // Tells GL what area we are rendering to. In our case, we use the full available
    // area. Without this, resizing the window would have no effect on rendering.
    void onWindowResize(int width, int height)
    {
        // bottom-left position.
        enum int x = 0;
        enum int y = 0;
        glViewport(x, y, width, height);
        windowWidth  = width;
        windowHeight = height;
    }

    void onScroll(double hOffset, double vOffset)
    {
        mouseScroll = -cast(int)vOffset;
    }

private:
    Window window;
    static dchar staticUnicode;

    int windowWidth;
    int windowHeight;

    int mouseScroll = 0;

    int sidebarScroll;
}

int main(string[] args)
{
    int width = 800, height = 600;

    auto window = createWindow("Despiker", WindowMode.windowed, width, height);
    GUI gui = GUI(window);

    glfwSwapInterval(1);

    string fontPath = thisExePath().dirName().buildPath("DroidSans.ttf");
    // string fontPath = thisExePath().dirName().buildPath("GentiumPlus-R.ttf");

    enforce(imguiInit(fontPath, 512));

    glClearColor(0.8f, 0.8f, 0.8f, 1.0f);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_DEPTH_TEST);

    try while (!glfwWindowShouldClose(window.window))
    {
        gui.render();

        // Swap front and back buffers
        window.swap_buffers();
        // Poll for and process events
        glfwPollEvents();

        if (window.is_key_down(GLFW_KEY_ESCAPE))
        {
            glfwSetWindowShouldClose(window.window, true);
        }
    }
    catch(Exception e)
    {
        writeln("CRASH: ", e.to!string);
    }

    // Clean UI
    imguiDestroy();

    return 0;
}
