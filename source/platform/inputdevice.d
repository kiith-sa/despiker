//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Handles user input (keyboard, windowing input such as closing the window, etc.).
module platform.inputdevice;


import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.experimental.logger;

import derelict.sdl2.sdl;

public import platform.inputrecording;
public import platform.key;

import io.yaml;


/// Handles user input (keyboard, mouse, windowing input such as resizing the window, etc.).
final class InputDevice
{
public:
    /** Status of window resizing.
     *
     * Implicitly converts info bool, so checks like if(input.resized) can be made.
     */
    struct ResizedStatus
    {
        // Has the window been resized?
        bool resized = false;

        alias resized this;

    private:
        // New width and height of the window after resizing.
        int width_, height_;

    public:
        /// Get the new window width. Can only be called if resized.
        int width() @safe pure nothrow const @nogc
        {
            assert(resized, "Trying to get new width when the window was not resized");
            return width_;
        }

        /// Get the new window height. Can only be called if resized.
        int height() @safe pure nothrow const @nogc
        {
            assert(resized, "Trying to get new height when the window was not resized");
            return height_;
        }
    }

package:
    // Game log.
    Logger log_;

private:
    // Keeps track of keyboard input.
    Keyboard keyboard_;

    // Keeps track of mouse input.
    Mouse mouse_;

    // Does the user want to quit the program?
    bool quit_;

    // Recording device used for recording input for benchmark demos.
    InputRecordingDevice recorder_;

    // State needed for replaying recorded input of one type (e.g. mouse or keyboard).
    struct ReplayState(Input)
    {
        // Currently playing input recording for Input. Null if no recording is playing.
        Recording!Input recording = null;

        // A HACK to ensure game state during a replay 'lines up' to state during recording.
        //
        // Specifies number of frames after replay() is called to wait before really starting
        // to replay.
        //
        // Without this, replaying recorded input is slightly 'off', e.g. the camera is moved
        // slightly less far, resulting in entities that were selected when recording not
        // being selected when replaying, etc.
        //
        // TODO: Try to figure out a way to fix this problem without this hack.
        //       (Note: the one-frame recording delay does not seem to be responsible)
        //       2014-09-11
        size_t delay;

        enum blockName = "block" ~ Input.stringof;
        // Should the real input be blocked while input is being replayed from recording?
        Flag!blockName block;
    }

    // State needed to replay recorded mouse input.
    ReplayState!Mouse replayM_;
    // State needed to replay recorded keyboard input.
    ReplayState!Keyboard replayK_;

    // Status of resizing the window (converts to true if window was resized this frame).
    ResizedStatus resized_;

    /* Acts as a queue of UTF-32 code points encoded in UTF-8.
     *
     * If not empty, one element is popped each frame.
     */
    char[] unicodeQueue_;

public:
    /** Construct an InputDevice.
     *
     * Params:
     *
     * getHeight = Delegate that returns window height.
     * log       = Game log.
     */
    this(long delegate() @safe pure nothrow @nogc getHeight, Logger log) @trusted nothrow
    {
        log_      = log;
        keyboard_ = new Keyboard();
        mouse_    = new Mouse(getHeight);
        recorder_ = new InputRecordingDevice(this);
        SDL_StartTextInput();
    }

    /// Destroy the InputDevice. Must be called to ensure deletion of manually allocated memory.
    ~this() @trusted
    {
        SDL_StopTextInput();
        destroy(recorder_);
    }

    /// Get a reference to the recording device to record input with.
    InputRecordingDevice recorder() @safe pure nothrow @nogc
    {
        return recorder_;
    }

    /** Start replaying mouse input from a recording.
     *
     * The recording will continue to play until it is spent.
     * Will consume the recording.
     *
     * If something is already replaying (from a previous replay() call), it will be
     * overridden.
     *
     * Params:
     *
     * recording = The recording to play. Will continue to play until spent. Will be 
     *             consumed by the InputDevice.
     * block     = Should input from the real mouse be blocked while replaying?
     */
    void replay(Recording!Mouse recording, Flag!"blockMouse" block) @safe pure nothrow @nogc
    {
        replayM_ = ReplayState!Mouse(recording, 1, block);
    }

    /** Start replaying keyboard input from a recording.
     *
     * If something is already replaying (from a previous replay() call), it will be
     * overridden.
     *
     * Params:
     *
     * recording = The recording to play. Will continue to play until spent. Will be 
     *             consumed by the InputDevice.
     * block     = Should input from the real keyboard be blocked while replaying?
     */
    void replay(Recording!Keyboard recording, Flag!"blockKeyboard" block)
        @safe pure nothrow @nogc
    {
        replayK_ = ReplayState!Keyboard(recording, 1, block);
    }

    /// Collect user input.
    void update() @trusted nothrow // @nogc
    {
        import std.utf;
        if(!unicodeQueue_.empty) try
        {
            unicodeQueue_.popFront();
        }
        catch(UTFException e)
        {
            log_.warning("Error in unicode input decoding, clearing unicode input")
                .assumeWontThrow;
            unicodeQueue_.length = 0;
        }
        catch(Exception e) { assert(false, "Unexpected exception"); }
        
        // Record input from the *previous frame* (avoids recording the current frame
        // of a stopRecord() call, which could record the input that stopped it)
        recorder_.update();

        SDL_PumpEvents();
        mouse_.clear();
        keyboard_.clear();

        if(!replayM_.block) { mouse_.getInput(); }
        if(!replayK_.block) { keyboard_.getInput(); }

        handleRecord(mouse_, replayM_);
        handleRecord(keyboard_, replayK_);

        resized_ = ResizedStatus.init;
        SDL_Event e;
        while(SDL_PollEvent(&e) != 0)
        {
            if(!replayM_.block) { mouse_.handleEvent(e); }
            // Quit if the user closes the window or presses Escape.
            if(e.type == SDL_QUIT) { quit_ = true; }
            if(e.type == SDL_WINDOWEVENT)
            {
                if(e.window.event == SDL_WINDOWEVENT_RESIZED)
                {
                    resized_ = ResizedStatus(true, e.window.data1, e.window.data2);
                }
            }
            if(e.type == SDL_TEXTINPUT)
            {
                unicodeQueue_.assumeSafeAppend();
                import core.stdc.string: strlen;
                unicodeQueue_ ~= e.text.text[0 .. strlen(e.text.text.ptr)];
            }
        }

        // Our GUI reads backspace/enter through unicode().
        if(keyboard_.pressed(Key.Return))    { unicodeQueue_ ~= 0x0D; }
        if(keyboard_.pressed(Key.Backspace)) { unicodeQueue_ ~= 0x08; }
    }

    /// Get access to keyboard input.
    const(Keyboard) keyboard() @safe pure nothrow const @nogc { return keyboard_; }

    /// Get access to mouse input.
    const(Mouse) mouse() @safe pure nothrow const @nogc { return mouse_; }

    /// Status of resizing the window (converts to true if window was resized this frame).
    ResizedStatus resized() @safe pure nothrow const @nogc { return resized_; }

    /// Does the user want to quit the program (e.g. by pressing the close window button).
    bool quit() @safe pure nothrow const @nogc { return quit_; }

    /** Get the "current" unicode character for text input purposes.
     *
     * Text input is pretty complicated and the InputDevice may (at least in theory)
     * receive more than one unicode character in some frames. These are stored in an
     * internal queue that is popped once per frame. This accesses the popped value.
     *
     * If there are no characters in the queue, 0 is returned. Enter/backspace key presses
     * are also registered as unicode characters (0x0D/0x0D respectively).
     *
     */
    dchar unicode() @safe pure nothrow const
    {
        if(unicodeQueue_.empty) { return 0; }

        import std.utf;
        // An error, if any, will be detected/logged on the next frame (no logging here - const)
        try { return unicodeQueue_.front; }
        catch(UTFException e) { return 0; }
        catch(Exception e) { assert(false, "Unexpected exception"); }
    }


private:
    /** If specified input recording is not null, attempts to play one frame from the recording.
     *
     * Params:
     *
     * input  = Input affected by the recording. E.g. mouse for a mouse input recording.
     * replay = The recording to play with some extra state. If the recording is null,
     *          handleRecord() will do anything. If it's empty, replay will be
     *          reset to its init value.
     */
    static void handleRecord(Input)(Input input, ref ReplayState!Input replay)
        @safe
    {
        scope(exit) if(replay.delay > 0) { --replay.delay; }
        if(replay.recording is null || replay.delay > 0) { return; }

        if(replay.recording.empty) 
        {
            replay = replay.init;
        }
        else
        {
            input.handleRecord(replay.recording.front);
            replay.recording.popFront();
        }
    }
}


import std.typecons;

/// Keeps track of which keys are pressed on the keyboard.
final class Keyboard
{
package:
    // Keyboard data members separated into a struct for easy recording.
    //
    // "Base" state because all other state (movement) can be derived from this data
    // (movement - change of BaseState between frames).
    struct BaseState
    {
        // Unlikely to have more than 256 keys pressed at any one time (we ignore any more).
        SDL_Keycode[256] pressedKeys_;
        // The number of values used in pressedKeys_.
        size_t pressedKeyCount_;

        // Convert a BaseState to a YAML node.
        YAMLNode toYAML() @safe nothrow const
        {
            auto pressedKeys = pressedKeys_[0 .. pressedKeyCount_];
            return YAMLNode(pressedKeys.map!(to!string).array.assumeWontThrow);
        }

        /* Load a BaseState from a YAML node (produced by BaseState.toYAML()).
         *
         * Throws:
         *
         * ConvException if any value in the YAML has unexpected format.
         * YAMLException if the YAML has unexpected layout.
         */
        static BaseState fromYAML(ref YAMLNode yaml) @safe
        {
            enforce(yaml.length <= pressedKeys_.length,
                    new YAMLException("Too many pressed keys in a record"));
            BaseState result;
            foreach(string key; yaml)
            {
                result.pressedKeys_[result.pressedKeyCount_++] = to!SDL_Keycode(key);
            }
            return result;
        }
    }

    BaseState baseState_;
    alias baseState_ this;

private:
    // pressedKeys_ from the last update, to detect that a key has just been pressed/released.
    SDL_Keycode[256] pressedKeysLastUpdate_;
    // The number of values used in pressedKeysLastUpdate_.
    size_t pressedKeyCountLastUpdate_;

public:
    /// Get the state of specified keyboard key.
    Flag!"isPressed" key(const Key keycode) @safe pure nothrow const @nogc
    {
        auto keys = pressedKeys_[0 .. pressedKeyCount_];
        return keys.canFind(cast(SDL_Keycode)keycode) ? Yes.isPressed : No.isPressed;
    }

    /// Determine if specified key was just pressed.
    Flag!"pressed" pressed(const Key keycode) @safe pure nothrow const @nogc
    {
        // If it is pressed now but wasn't pressed the last frame, it has just been pressed.
        auto keys = pressedKeysLastUpdate_[0 .. pressedKeyCountLastUpdate_];
        const sdlKey = cast(SDL_Keycode)keycode;
        return (key(keycode) && !keys.canFind(sdlKey)) ? Yes.pressed : No.pressed;
    }

private:
    /// Clear any keyboard state that must be cleared every frame.
    void clear() @safe pure nothrow @nogc
    {
        pressedKeysLastUpdate_[]   = pressedKeys_[];
        pressedKeyCountLastUpdate_ = pressedKeyCount_;
        pressedKeyCount_ = 0;
    }

    /// Get keyboard input that must be refreshed every frame.
    void getInput() @system nothrow @nogc
    {
        int numKeys;
        const Uint8* allKeys = SDL_GetKeyboardState(&numKeys);
        foreach(SDL_Scancode scancode, Uint8 state; allKeys[0 .. numKeys])
        {
            if(!state) { continue; }
            pressedKeys_[pressedKeyCount_++] = SDL_GetKeyFromScancode(scancode);
        }
    }

    /** Load base state from a record.
     *
     * Pressed keys on the keyboard are combined with pressed keys loaded from the record.
     */
    void handleRecord(ref const BaseState state) @safe pure nothrow @nogc
    {
        foreach(key; state.pressedKeys_[0 .. state.pressedKeyCount_])
        {
            // Ignore more than 256 keys pressed at the same time.
            if(pressedKeyCount_ >= pressedKeys_.length) { return; }
            pressedKeys_[pressedKeyCount_++] = key;
        }
    }
}

/// Keeps track of mouse position, buttons, dragging, etc.
final class Mouse
{
package:
    // Mouse data members separated into a struct for easy recording.
    //
    // "Base" state because all other state (movement) can be derived from this data
    // (movement - change of BaseState between frames).
    struct BaseState
    {
        // X coordinate of mouse position.
        int x_;
        // Y coordinate of mouse position.
        int y_;

        // X coordinate of the mouse wheel (if the wheel supports horizontal scrolling).
        int wheelX_;
        // Y coordinate of the mouse wheel (aka scrolling with a normal wheel).
        int wheelY_;

        // Did the user finish a click with a button during this update?
        Flag!"click"[Button.max + 1] click_;

        // Did the user finish a doubleclick with a button during this update?
        Flag!"doubleClick"[Button.max + 1] doubleClick_;

        // State of all (well, at most 5) mouse buttons.
        Flag!"pressed"[Button.max + 1] buttons_;

        // Convert a BaseState to a YAML node.
        YAMLNode toYAML() @safe nothrow const
        {
            string[] keys;
            YAMLNode[] values;
            keys ~= "x"; values ~= YAMLNode(x_);
            keys ~= "y"; values ~= YAMLNode(y_);
            keys ~= "wheelX"; values ~= YAMLNode(wheelX_);
            keys ~= "wheelY"; values ~= YAMLNode(wheelY_);

            keys ~= "click";
            values ~= YAMLNode(click_[].map!(to!string).array.assumeWontThrow);
            keys ~= "doubleClick";
            values ~= YAMLNode(doubleClick_[].map!(to!string).array.assumeWontThrow);
            keys ~= "buttons";
            values ~= YAMLNode(buttons_[].map!(to!string).array.assumeWontThrow);
            return YAMLNode(keys, values);
        }

        /* Load a BaseState from a YAML node (produced by BaseState.toYAML()).
         *
         * Throws:
         *
         * ConvException if any value in the YAML has unexpected format.
         * YAMLException if the YAML has unexpected layout.
         */
        static BaseState fromYAML(ref YAMLNode yaml) @safe
        {
            // Used to load button arrays (buttons_, click_, doubleClick_)
            void buttonsFromYAML(F)(F[] flags, ref YAMLNode seq)
            {
                enforce(seq.length <= flags.length,
                        new YAMLException("Too many mouse buttons in recording"));
                size_t idx = 0;
                foreach(string button; seq) { flags[idx++] = button.to!F; }
            }
            BaseState result;
            foreach(string key, ref YAMLNode value; yaml) switch(key)
            {
                case "x":           result.x_      = value.as!int;                 break;
                case "y":           result.y_      = value.as!int;                 break;
                case "wheelX":      result.wheelX_ = value.as!int;                 break;
                case "wheelY":      result.wheelY_ = value.as!int;                 break;
                case "click":       buttonsFromYAML(result.click_[],       value); break;
                case "doubleClick": buttonsFromYAML(result.doubleClick_[], value); break;
                case "buttons":     buttonsFromYAML(result.buttons_[],     value); break;
                default: throw new YAMLException("Unknown key in mouse record: " ~ key);
            }
            return result;
        }
    }

    BaseState baseState_;
    alias baseState_ this;

private:
    // Y movement of mouse since the last update.
    int xMovement_;
    // Y movement of mouse since the last update.
    int yMovement_;

    // X movement of the wheel since the last update.
    int wheelYMovement_;
    // Y movement of the wheel since the last update.
    int wheelXMovement_;

    // State of all (well, at most 5) mouse buttons.
    Flag!"pressed"[Button.max + 1] buttonsLastUpdate_;

    // Coordinates where each button was last pressed (for dragging).
    vec2i[Button.max + 1] pressedCoords_;

    // Gets the current window height.
    long delegate() @safe pure nothrow @nogc getHeight_;

    import gl3n_extra.linalg;

public:
nothrow @nogc:
    /// Enumerates mouse buttons.
    enum Button: ubyte
    {
        Left    = 0,
        Middle  = 1,
        Right   = 2,
        X1      = 3,
        X2      = 4,
        // Using 16 to avoid too big BaseState arrays.
        Unknown = 16
    }

    /** Construct a Mouse and initialize button states.
     *
     * Params:
     *
     * getHeight = Delegate that returns current window height.
     */
    this(long delegate() @safe pure nothrow @nogc getHeight) @safe nothrow
    {
        getHeight_ = getHeight;
        xMovement_ = yMovement_ = 0;
        getMouseState();
    }

@safe pure const
{
    /// Get X coordinate of mouse position.
    int x() { return x_; }
    /// Get Y coordinate of mouse position.
    int y() { return y_; }

    /// Get X movement of mouse since the last update.
    int xMovement() { return xMovement_; }
    /// Get Y movement of mouse since the last update.
    int yMovement() { return yMovement_; }

    /// Get X coordinate of the mouse wheel (if it supports horizontal scrolling).
    int wheelX() { return wheelX_; }
    /// Get Y coordinate of the mouse wheel.
    int wheelY() { return wheelY_; }

    /// Get the X movement of the wheel since the last update.
    int wheelXMovement() { return wheelXMovement_; }
    /// Get the Y movement of the wheel since the last update.
    int wheelYMovement() { return wheelYMovement_; }

    /// Did the user finish a double click during this update?
    Flag!"doubleClick" doubleClicked(Button button) { return doubleClick_[button]; }
    /// Did the user finish a click during this update?
    Flag!"click" clicked(Button button) { return click_[button]; }
    /// Get the state of specified mouse button.
    Flag!"pressed" button(Button button) { return buttons_[button]; }

    /// Get the coordinates at which button was last pressed. Useful for dragging.
    vec2i pressedCoords(Button button) { return pressedCoords_[button]; }
}

private:
    /// Handle an SDL event (which may be a mouse event).
    void handleEvent(ref const SDL_Event e) @system nothrow
    {
        static Button button(Uint8 sdlButton) @safe pure nothrow @nogc
        {
            switch(sdlButton)
            {
                case SDL_BUTTON_LEFT:   return Button.Left;
                case SDL_BUTTON_MIDDLE: return Button.Middle;
                case SDL_BUTTON_RIGHT:  return Button.Right;
                case SDL_BUTTON_X1:     return Button.X1;
                case SDL_BUTTON_X2:     return Button.X2;
                // SDL should not report any other value for mouse buttons... but it does.
                default: return Button.Unknown; // assert(false, "Unknown mouse button");
            }
        }
        switch(e.type)
        {
            case SDL_MOUSEMOTION: break;
            case SDL_MOUSEWHEEL:
                wheelX_ += e.wheel.x;
                wheelY_ += e.wheel.y;
                // += is needed because there might be multiple wheel events per frame.
                wheelXMovement_ += e.wheel.x;
                wheelYMovement_ += e.wheel.y;
                break;
            case SDL_MOUSEBUTTONUP:
                const b = button(e.button.button);
                // Don't set to No.click so we don't override clicks from any playing recording.
                if(e.button.clicks > 0)      { click_[b]       = Yes.click; }
                if(e.button.clicks % 2 == 0) { doubleClick_[b] = Yes.doubleClick; }
                break;
            case SDL_MOUSEBUTTONDOWN:
                // Save the coords where the button was pressed (for dragging).
                pressedCoords_[button(e.button.button)] = vec2i(x_, y_);
                break;
            default: break;
        }
    }

    /// Clear any mouse state that must be cleared every frame.
    void clear() @safe pure nothrow @nogc
    {
        xMovement_      = yMovement_      = 0;
        wheelXMovement_ = wheelYMovement_ = 0;
        click_[]       = No.click;
        doubleClick_[] = No.doubleClick;
        buttonsLastUpdate_[] = buttons_[];
        buttons_[] = No.pressed;
    }

    /// Get mouse input that must be refreshed every frame.
    void getInput() @safe nothrow 
    {
        const oldX = x_; const oldY = y_;
        getMouseState();
        xMovement_ = x_ - oldX; yMovement_ = y_ - oldY;
    }

    /** Load base state from a record.
     *
     * Mouse cursor and wheel coordinates are considered absolute; i.e. recorded coords
     * override current cursor/wheel position.
     *
     * Button clicks are not absolute; any clicks from the record are added to clicks
     * registered from current input. Same for pressed buttons.
     */
    void handleRecord(ref const BaseState state) @safe pure nothrow @nogc
    {
        xMovement_ += state.x_ - x_;
        yMovement_ += state.y_ - y_;
        x_ = state.x_;
        y_ = state.y_;

        wheelXMovement_ += state.wheelX_ - wheelX_;
        wheelYMovement_ += state.wheelY_ - wheelY_;
        wheelX_ = state.wheelX_;
        wheelY_ = state.wheelY_;

        foreach(button; 0 .. Button.max + 1)
        {
            // A button has been 'pressed' from the recording
            const justPressed = !buttonsLastUpdate_[button] && state.buttons_[button];
            // If no click in record, we keep the click/no click from user input.
            if(state.click_[button])       { click_[button]         = Yes.click;       }
            if(state.doubleClick_[button]) { doubleClick_[button]   = Yes.doubleClick; }
            if(state.buttons_[button])     { buttons_[button]       = Yes.pressed;     }
            if(justPressed)                { pressedCoords_[button] = vec2i(x_, y_);   }
        }
    }

    /// Get mouse position and button state.
    void getMouseState() @trusted nothrow
    {
        const buttons = SDL_GetMouseState(&x_, &y_);
        buttons_[Button.Left]   = buttons & SDL_BUTTON_LMASK  ? Yes.pressed : No.pressed;
        buttons_[Button.Middle] = buttons & SDL_BUTTON_MMASK  ? Yes.pressed : No.pressed;
        buttons_[Button.Right]  = buttons & SDL_BUTTON_RMASK  ? Yes.pressed : No.pressed;
        buttons_[Button.X1]     = buttons & SDL_BUTTON_X1MASK ? Yes.pressed : No.pressed;
        buttons_[Button.X2]     = buttons & SDL_BUTTON_X2MASK ? Yes.pressed : No.pressed;
        y_ = cast(int)(getHeight_() - y_);
    }
}

// TODO: 'MappedInput' to wrap Mouse/Keyboard. Will read keybrd/mouse mappings from YAML.
// Its API will use enum values (InputAction?) instead of keys, e.g. InputAction.Attack,
// -||-.Deploy, -||-.SelectAllThisType, etc; InputActions will map to loaded mappings, and
// the API will expose mouse *position* (and pos where mouse was last _pressed_), so user
// can e.g. detect that InputAction.Select is active (e.g.  left click), and get mouse pos
// to know what to select. With mapping, Select can be mapped e.g. to Enter so user can
// select units by mouse over + Enter instead of left-click. 2014-08-26
//
// Would also allow support for e.g. gamepads (not that it makes sense... maybe Steam
// Controller?)
