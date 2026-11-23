#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Uso: $0 <ruta_de_rom.gb> [--debug|--release] [--install] [--run]"
    echo "  --debug    Compila APK Debug"
    echo "  --release  Compila APK Release firmado para distribuir (por defecto)"
    echo "  --install  Instala el APK en el dispositivo conectado por adb"
    echo "  --run      Instala y abre la app automaticamente por adb"
    exit 0
fi

ROM_PATH="$(realpath "$1")"
shift

if [ ! -f "$ROM_PATH" ]; then
    echo "Error: No se encontro la ROM en '$ROM_PATH'" >&2
    exit 1
fi

BUILD_TYPE="Release"
INSTALL_APK=false
LAUNCH_APP=false

for arg in "$@"; do
    case "$arg" in
        --debug)
            BUILD_TYPE="Debug"
            ;;
        --release)
            BUILD_TYPE="Release"
            ;;
        --install)
            INSTALL_APK=true
            ;;
        --run)
            INSTALL_APK=true
            LAUNCH_APP=true
            ;;
        *)
            echo "Opcion desconocida: $arg" >&2
            exit 1
            ;;
    esac
done

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$WORK_DIR/recomp_android"
REPO_DIR="$WORK_DIR/gb-recompiled"
ROM_STEM="$(basename "$ROM_PATH")"
ROM_STEM="${ROM_STEM%.*}"
PKG_SUFFIX="$(echo "$ROM_STEM" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')"
[ -z "$PKG_SUFFIX" ] && PKG_SUFFIX="game"
PACKAGE_NAME="io.gbrecompiled.$PKG_SUFFIX"
APP_NAME="Kirby Dream Land"
if [ "$PKG_SUFFIX" != "kirby" ]; then
    APP_NAME="$ROM_STEM"
fi

# 1. Clonar gb-recompiled solo si no existe
if [ ! -d "$REPO_DIR" ]; then
    echo "==> Clonando gb-recompiled..."
    git clone https://github.com/arcanite24/gb-recompiled.git "$REPO_DIR"
else
    echo "==> Usando gb-recompiled existente en $REPO_DIR"
fi

# 2. Detectar o descargar SDL2-2.30.9
if [ -z "${SDL2_SOURCE_DIR:-}" ]; then
    for candidate in "$WORK_DIR/SDL2-2.30.9" "$WORK_DIR/SDL2"; do
        if [ -f "$candidate/CMakeLists.txt" ]; then
            SDL2_SOURCE_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "${SDL2_SOURCE_DIR:-}" ] || [ ! -f "$SDL2_SOURCE_DIR/CMakeLists.txt" ]; then
    echo "==> Descargando SDL2-2.30.9..."
    curl -fL "https://github.com/libsdl-org/SDL/releases/download/release-2.30.9/SDL2-2.30.9.tar.gz" -o "$WORK_DIR/SDL2.tar.gz"
    tar -xzf "$WORK_DIR/SDL2.tar.gz" -C "$WORK_DIR"
    SDL2_SOURCE_DIR="$WORK_DIR/SDL2-2.30.9"
fi

# 3. Construir gbrecomp
echo "==> Compilando gbrecomp..."
cmake -G Ninja -S "$REPO_DIR" -B "$REPO_DIR/build"
ninja -C "$REPO_DIR/build"

# 4. Generar proyecto Android en recomp_android
echo "==> Generando proyecto Android en $OUT_DIR..."
"$REPO_DIR/build/bin/gbrecomp" "$ROM_PATH" \
    --output "$OUT_DIR" \
    --android \
    --android-package "$PACKAGE_NAME" \
    --android-app-name "$APP_NAME"

# 5. Aplicar parches de Android (gbrt CMake + soporte multi-control / 8BitDo Ultimate 2 + firma release)
echo "==> Aplicando parches para Android (controles + CMake gbrt)..."
python3 - "$OUT_DIR" <<'PYEOF'
import pathlib, sys

out_dir = pathlib.Path(sys.argv[1])

# 5a. Agregar fuentes faltantes de gbrt en android/app/jni/src/CMakeLists.txt
cmake_path = out_dir / "android/app/jni/src/CMakeLists.txt"
cmake_text = cmake_path.read_text(encoding="utf-8")
old_gbrt = """add_library(gbrt STATIC
    ${GBRT_DIR}/src/gbrt.c
    ${GBRT_DIR}/src/differential.c"""
new_gbrt = """add_library(gbrt STATIC
    ${GBRT_DIR}/src/gbrt.c
    ${GBRT_DIR}/src/gbrt_data_mod.c
    ${GBRT_DIR}/src/gbrt_hash.c
    ${GBRT_DIR}/src/gbrt_host_configuration.c
    ${GBRT_DIR}/src/gbrt_port.c
    ${GBRT_DIR}/src/gbrt_presentation.c
    ${GBRT_DIR}/src/gbrt_semantic.c
    ${GBRT_DIR}/src/differential.c"""
if old_gbrt in cmake_text:
    cmake_path.write_text(cmake_text.replace(old_gbrt, new_gbrt, 1), encoding="utf-8")

# 5b. Parchear runtime/src/platform_sdl.cpp para multi-control + mapeo fallback Android (8BitDo Ultimate 2)
sdl_path = out_dir / "runtime/src/platform_sdl.cpp"
sdl_text = sdl_path.read_text(encoding="utf-8")

replacements = [
    (
        "static SDL_GameController* g_controller = NULL;",
        "static SDL_GameController* g_controller = NULL;\nstatic std::vector<SDL_GameController*> g_controllers;",
    ),
    (
        """static bool should_ignore_controller_name(const char* name) {
    return string_contains_case_insensitive(name, "qwerty") ||
           string_contains_case_insensitive(name, "keyboard") ||
           string_contains_case_insensitive(name, "keypad");
}""",
        """static bool should_ignore_controller_name(const char* name) {
    return string_contains_case_insensitive(name, "qwerty") ||
           string_contains_case_insensitive(name, "keyboard") ||
           string_contains_case_insensitive(name, "keypad") ||
           string_contains_case_insensitive(name, "accelerometer") ||
           string_contains_case_insensitive(name, "sensor") ||
           string_contains_case_insensitive(name, "fingerprint") ||
           string_contains_case_insensitive(name, "touch") ||
           string_contains_case_insensitive(name, "mouse") ||
           string_contains_case_insensitive(name, "trackpad") ||
           string_contains_case_insensitive(name, "gpio") ||
           string_contains_case_insensitive(name, "uinput-fpc") ||
           string_contains_case_insensitive(name, "pmic") ||
           string_contains_case_insensitive(name, "headset") ||
           string_contains_case_insensitive(name, "avrcp");
}""",
    ),
    (
        'string_contains_case_insensitive(name, "xinput") ||',
        'string_contains_case_insensitive(name, "xinput") ||\n            string_contains_case_insensitive(name, "8bitdo") ||',
    ),
    (
        """static void clear_controller_state(void) {
    if (g_controller) {
        SDL_GameControllerClose(g_controller);
        g_controller = NULL;
    }
    memset(g_controller_button_binding_pressed, 0, sizeof(g_controller_button_binding_pressed));
    memset(g_controller_axis_binding_pressed, 0, sizeof(g_controller_axis_binding_pressed));
    memset(g_controller_axis_values, 0, sizeof(g_controller_axis_values));
    g_controller_type = SDL_CONTROLLER_TYPE_UNKNOWN;
    g_controller_label_profile = detect_controller_label_profile(NULL);
    g_controller_name.clear();
    update_effective_joypad_state();
}

static void refresh_controller_profile(void) {
    if (!g_controller) {
        g_controller_type = SDL_CONTROLLER_TYPE_UNKNOWN;
        g_controller_label_profile = detect_controller_label_profile(NULL);
        g_controller_name.clear();
        return;
    }

    g_controller_type = SDL_GameControllerGetType(g_controller);
    g_controller_label_profile = detect_controller_label_profile(g_controller);
    const char* name = SDL_GameControllerName(g_controller);
    g_controller_name = (name && name[0]) ? name : "Controller";
    fprintf(stderr,
            "[SDL] Controller: %s [%s]\\n",
            g_controller_name.c_str(),
            controller_type_name(g_controller_type));
}

static bool open_controller_index(int joystick_index) {
    if (joystick_index < 0 || joystick_index >= SDL_NumJoysticks() || !SDL_IsGameController(joystick_index)) {
        return false;
    }

    SDL_GameController* controller = SDL_GameControllerOpen(joystick_index);
    if (!controller) {
        return false;
    }

    if (should_ignore_controller_name(SDL_GameControllerName(controller))) {
        SDL_GameControllerClose(controller);
        return false;
    }

    clear_controller_state();
    g_controller = controller;
    refresh_controller_profile();
    return true;
}

static bool open_first_available_controller(void) {
    if (g_controller) {
        return true;
    }

    for (int i = 0; i < SDL_NumJoysticks(); i++) {
        if (open_controller_index(i)) {
            return true;
        }
    }
    return false;
}""",
        """static SDL_JoystickID controller_instance_id(SDL_GameController* controller) {
    if (!controller) return -1;
    SDL_Joystick* joystick = SDL_GameControllerGetJoystick(controller);
    return joystick ? SDL_JoystickInstanceID(joystick) : -1;
}

static SDL_GameController* find_controller_by_instance_id(SDL_JoystickID instance_id) {
    for (SDL_GameController* controller : g_controllers) {
        if (controller_instance_id(controller) == instance_id) return controller;
    }
    return NULL;
}

static void clear_controller_input_state(void) {
    memset(g_controller_button_binding_pressed, 0, sizeof(g_controller_button_binding_pressed));
    memset(g_controller_axis_binding_pressed, 0, sizeof(g_controller_axis_binding_pressed));
    memset(g_controller_axis_values, 0, sizeof(g_controller_axis_values));
    update_effective_joypad_state();
}

static void clear_controller_state(void) {
    for (SDL_GameController* controller : g_controllers) {
        if (controller) SDL_GameControllerClose(controller);
    }
    g_controllers.clear();
    g_controller = NULL;
    clear_controller_input_state();
    g_controller_type = SDL_CONTROLLER_TYPE_UNKNOWN;
    g_controller_label_profile = detect_controller_label_profile(NULL);
    g_controller_name.clear();
}

static void refresh_controller_profile(void) {
    if (!g_controller) {
        g_controller_type = SDL_CONTROLLER_TYPE_UNKNOWN;
        g_controller_label_profile = detect_controller_label_profile(NULL);
        g_controller_name.clear();
        return;
    }
    g_controller_type = SDL_GameControllerGetType(g_controller);
    g_controller_label_profile = detect_controller_label_profile(g_controller);
    const char* name = SDL_GameControllerName(g_controller);
    g_controller_name = (name && name[0]) ? name : "Controller";
    SDL_Log("[SDL] Active controller: %s [%s] (open=%zu)",
            g_controller_name.c_str(),
            controller_type_name(g_controller_type),
            g_controllers.size());
}

static void activate_controller_by_instance_id(SDL_JoystickID instance_id) {
    SDL_GameController* controller = find_controller_by_instance_id(instance_id);
    if (controller && controller != g_controller) {
        g_controller = controller;
        refresh_controller_profile();
    }
}

static bool ensure_android_fallback_mapping(int joystick_index) {
#if defined(__ANDROID__)
    if (SDL_IsGameController(joystick_index)) return true;
    const char* raw_name = SDL_JoystickNameForIndex(joystick_index);
    if (should_ignore_controller_name(raw_name)) return false;
    SDL_Joystick* probe = SDL_JoystickOpen(joystick_index);
    if (!probe) return false;
    const int num_buttons = SDL_JoystickNumButtons(probe);
    const int num_axes = SDL_JoystickNumAxes(probe);
    const SDL_JoystickGUID guid = SDL_JoystickGetGUID(probe);
    SDL_JoystickClose(probe);
    if (num_buttons < 4 && num_axes < 2) return false;
    char guid_str[64] = {};
    SDL_JoystickGetGUIDString(guid, guid_str, sizeof(guid_str));
    std::string safe_name = (raw_name && raw_name[0]) ? std::string(raw_name) : std::string("Android Gamepad");
    for (char& ch : safe_name) {
        if (ch == ',' || ch == '\\n' || ch == '\\r') ch = ' ';
    }
    std::string mapping = std::string(guid_str) + "," + safe_name + ",";
    if (num_buttons > 20) {
        if (num_buttons > 30) {
            mapping += "a:b20,b:b21,x:b23,y:b24,leftshoulder:b26,rightshoulder:b27,back:b30,start:b31,leftstick:b33,rightstick:b34,";
        } else {
            mapping += "a:b20,b:b21,x:b22,y:b23,leftshoulder:b24,rightshoulder:b25,back:b28,start:b29,";
        }
    } else {
        mapping += "a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,leftstick:b7,rightstick:b8,leftshoulder:b9,rightshoulder:b10,";
    }
    mapping += "dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,";
    if (num_axes >= 2) mapping += "leftx:a0,lefty:a1,";
    if (num_axes >= 4) mapping += "rightx:a2,righty:a3,";
    if (num_axes >= 6) mapping += "lefttrigger:a4,righttrigger:a5,";
    mapping += "platform:Android,";
    SDL_GameControllerAddMapping(mapping.c_str());
    return SDL_IsGameController(joystick_index) == SDL_TRUE;
#else
    (void)joystick_index;
    return false;
#endif
}

static bool open_controller_index(int joystick_index) {
    if (joystick_index < 0 || joystick_index >= SDL_NumJoysticks()) return false;
    const char* joy_name = SDL_JoystickNameForIndex(joystick_index);
    const SDL_JoystickID instance_id = SDL_JoystickGetDeviceInstanceID(joystick_index);
    if (instance_id >= 0 && find_controller_by_instance_id(instance_id) != NULL) return true;
    if (should_ignore_controller_name(joy_name)) return false;
    if (!SDL_IsGameController(joystick_index)) ensure_android_fallback_mapping(joystick_index);
    if (!SDL_IsGameController(joystick_index)) return false;
    SDL_GameController* controller = SDL_GameControllerOpen(joystick_index);
    if (!controller) return false;
    if (should_ignore_controller_name(SDL_GameControllerName(controller))) {
        SDL_GameControllerClose(controller);
        return false;
    }
    g_controllers.push_back(controller);
    if (!g_controller || SDL_GameControllerGetType(g_controller) == SDL_CONTROLLER_TYPE_VIRTUAL) {
        g_controller = controller;
        refresh_controller_profile();
    }
    return true;
}

static void close_controller_by_instance_id(SDL_JoystickID instance_id) {
    bool removed = false;
    bool removed_active = false;
    for (auto it = g_controllers.begin(); it != g_controllers.end(); ) {
        if (controller_instance_id(*it) == instance_id) {
            if (*it == g_controller) removed_active = true;
            SDL_GameControllerClose(*it);
            it = g_controllers.erase(it);
            removed = true;
        } else {
            ++it;
        }
    }
    if (removed) {
        clear_controller_input_state();
        if (removed_active) {
            g_controller = g_controllers.empty() ? NULL : g_controllers.back();
            refresh_controller_profile();
        }
    }
}

static bool open_all_available_controllers(void) {
    bool opened_any = !g_controllers.empty();
    for (int i = 0; i < SDL_NumJoysticks(); i++) {
        if (open_controller_index(i)) opened_any = true;
    }
    return opened_any;
}""",
    ),
    (
        '    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");',
        '    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");\n    SDL_SetHint(SDL_HINT_TV_REMOTE_AS_JOYSTICK, "0");',
    ),
    (
        "    open_first_available_controller();",
        "    open_all_available_controllers();",
    ),
    (
        """        case SDL_CONTROLLERDEVICEADDED:
            if (!g_controller) {
                open_controller_index(event->cdevice.which);
            }
            break;

        case SDL_CONTROLLERDEVICEREMOVED:
            if (g_controller && active_controller_instance_id() == event->cdevice.which) {
                clear_controller_state();
                open_first_available_controller();
            }
            break;""",
        """        case SDL_JOYDEVICEADDED:
            open_controller_index(event->jdevice.which);
            break;

        case SDL_CONTROLLERDEVICEADDED:
            open_controller_index(event->cdevice.which);
            break;

        case SDL_JOYDEVICEREMOVED:
            close_controller_by_instance_id(event->jdevice.which);
            break;

        case SDL_CONTROLLERDEVICEREMOVED:
            close_controller_by_instance_id(event->cdevice.which);
            break;""",
    ),
    (
        """        case SDL_CONTROLLERAXISMOTION: {
            uint8_t previous_dpad = g_joypad_dpad;""",
        """        case SDL_CONTROLLERAXISMOTION: {
            if (event->caxis.value >= 16000 || event->caxis.value <= -16000) {
                activate_controller_by_instance_id(event->caxis.which);
            }
            uint8_t previous_dpad = g_joypad_dpad;""",
    ),
    (
        """        case SDL_CONTROLLERBUTTONDOWN:
        case SDL_CONTROLLERBUTTONUP: {
            const bool pressed = (event->type == SDL_CONTROLLERBUTTONDOWN);
            uint8_t previous_dpad = g_joypad_dpad;""",
        """        case SDL_CONTROLLERBUTTONDOWN:
        case SDL_CONTROLLERBUTTONUP: {
            const bool pressed = (event->type == SDL_CONTROLLERBUTTONDOWN);
            if (pressed) {
                activate_controller_by_instance_id(event->cbutton.which);
            }
            uint8_t previous_dpad = g_joypad_dpad;""",
    ),
]

for old, new in replacements:
    if old in sdl_text:
        sdl_text = sdl_text.replace(old, new, 1)

sdl_path.write_text(sdl_text, encoding="utf-8")

# 5c. Configurar firma Release en android/app/build.gradle
gradle_path = out_dir / "android/app/build.gradle"
gradle_text = gradle_path.read_text(encoding="utf-8")
old_bt = """    buildTypes {
        debug {
            debuggable true
        }
        release {
            minifyEnabled false
            proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"
        }
    }"""
new_bt = """    signingConfigs {
        release {
            storeFile file("../release.jks")
            storePassword "gbrecomp123"
            keyAlias "gbrecomp"
            keyPassword "gbrecomp123"
        }
    }

    buildTypes {
        debug {
            debuggable true
        }
        release {
            minifyEnabled false
            signingConfig signingConfigs.release
            proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"
        }
    }"""
if old_bt in gradle_text:
    gradle_path.write_text(gradle_text.replace(old_bt, new_bt, 1), encoding="utf-8")
PYEOF

# 6. Generar keystore de firma si se compila Release
if [ "$BUILD_TYPE" = "Release" ] && [ ! -f "$OUT_DIR/android/release.jks" ]; then
    echo "==> Generando keystore de firma Release..."
    keytool -genkeypair -v \
        -keystore "$OUT_DIR/android/release.jks" \
        -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 \
        -alias gbrecomp -storepass gbrecomp123 -keypass gbrecomp123 \
        -dname "CN=GBRecompiled, OU=Dev, O=GBRecompiled, L=MX, S=MX, C=MX"
fi

# 7. Compilar APK con Gradle
echo "==> Compilando APK ($BUILD_TYPE) con SDL2_SOURCE_DIR=$SDL2_SOURCE_DIR..."
if [ "$BUILD_TYPE" = "Release" ]; then
    SDL2_SOURCE_DIR="$SDL2_SOURCE_DIR" gradle -p "$OUT_DIR/android" :app:assembleRelease
    APK_PATH="$OUT_DIR/android/app/build/outputs/apk/release/app-release.apk"
else
    SDL2_SOURCE_DIR="$SDL2_SOURCE_DIR" gradle -p "$OUT_DIR/android" :app:assembleDebug
    APK_PATH="$OUT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
fi

echo ""
echo "==> APK generado: $APK_PATH"

if [ "$INSTALL_APK" = true ]; then
    echo "==> Instalando APK via adb..."
    adb install -r "$APK_PATH"
fi

if [ "$LAUNCH_APP" = true ]; then
    echo "==> Iniciando $PACKAGE_NAME/.GameActivity..."
    adb shell am start -W "$PACKAGE_NAME/.GameActivity"
fi
