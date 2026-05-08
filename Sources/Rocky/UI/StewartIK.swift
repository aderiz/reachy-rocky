import Foundation
import JavaScriptCore

/// Bridges the bundled `reachy_mini_kinematics.wasm` into Swift so the
/// avatar can compute the 18 Stewart-platform passive-joint angles
/// from the 6 motor angles + 2 antenna angles, exactly as the Pollen
/// Tauri app does.
///
/// The wasm module is built with wasm-bindgen (Rust → wasm). Its only
/// exported function we need is:
///
///     calculate_passive_joints(headJoints, antennas) -> [18 doubles]
///
/// Inputs are two `Float64Array`s. The output is a flat 18-element
/// array in URDF order:
///
///     [passive_1_x, passive_1_y, passive_1_z,
///      passive_2_x, passive_2_y, passive_2_z,
///      ...
///      passive_6_x, passive_6_y, passive_6_z]
///
/// Loading is synchronous — we use `new WebAssembly.Module` /
/// `new WebAssembly.Instance` instead of the async `instantiate`
/// path so the avatar can call into the IK on every state update
/// without juggling promises.
///
/// Wasm bytes are passed from Swift to JavaScriptCore as a Uint8Array
/// via the `JSObjectMakeTypedArrayWithBytesNoCopy` C API — base64
/// trips the bundle's size into the 50 KB range and adds a parse
/// hop for no benefit.
final class StewartIK {
    private let context = JSContext()!
    private let stewart: JSValue

    init(wasmURL: URL) throws {
        // Quiet exception trap — surface anything the JS side throws
        // as a Swift error rather than silently failing.
        var jsError: Error?
        context.exceptionHandler = { _, exc in
            let msg = exc?.toString() ?? "unknown JS exception"
            jsError = StewartIKError.jsException(msg)
        }

        // 1. Define the JS shim that wraps the wasm exports. Bound to a
        // global `Stewart` object so we can call methods on it
        // synchronously from Swift.
        context.evaluateScript(Self.jsShim)
        if let jsError { throw jsError }

        guard let stewart = context.objectForKeyedSubscript("Stewart") else {
            throw StewartIKError.shimUnavailable
        }
        self.stewart = stewart

        // 2. Load the wasm bytes.
        let wasmData = try Data(contentsOf: wasmURL)
        let bytesValue = Self.makeUint8Array(from: wasmData, in: context)
        context.setObject(bytesValue, forKeyedSubscript: "_rockyWasmBytes" as NSString)

        // 3. Init the wasm module synchronously.
        context.evaluateScript("Stewart.init(_rockyWasmBytes);")
        if let jsError { throw jsError }
        // Drop the bytes from the global scope — they're inside the
        // wasm module's memory now and the JS reference would just
        // pin a copy.
        context.evaluateScript("_rockyWasmBytes = null;")
    }

    /// Run the wasm IK. Returns 18 passive-joint angles, or nil on
    /// failure (wasm exception, bad input length, JSC error). The
    /// avatar treats nil as "skip the passive joint update this
    /// tick" — better than freezing the rods at a stale value.
    func calculatePassiveJoints(
        headJoints: [Double], antennas: [Double]
    ) -> [Double]? {
        guard headJoints.count == 6, antennas.count == 2 else { return nil }
        guard let result = stewart.invokeMethod(
            "calculatePassive", withArguments: [headJoints, antennas]
        ), !result.isUndefined, !result.isNull else {
            return nil
        }
        guard let array = result.toArray() as? [Double], array.count == 18 else {
            return nil
        }
        return array
    }

    // MARK: - JS shim

    /// Minimal hand-written equivalent of the bundle's
    /// `reachy_mini_kinematics.js`, simplified to:
    ///   - synchronous init via `new WebAssembly.Module / Instance`
    ///   - one method per public surface
    ///   - no ES module exports (so plain `evaluateScript` works)
    ///
    /// The implementation mirrors what wasm-bindgen produces for a
    /// `Vec<f64>` return: the wasm function gets `(ptr, len)` for
    /// each input array and returns a tuple-as-array `[ptr, len]`.
    private static let jsShim = """
    var Stewart = (function() {
        var exports = null;
        var memCache = null;

        function mem() {
            if (memCache === null || memCache.byteLength === 0) {
                memCache = new Float64Array(exports.memory.buffer);
            }
            return memCache;
        }

        function passIn(arr) {
            var ptr = exports.__wbindgen_malloc(arr.length * 8, 8) >>> 0;
            mem().set(arr, ptr / 8);
            return [ptr, arr.length];
        }

        function getOut(ptr, len) {
            return mem().subarray(ptr / 8, ptr / 8 + len).slice();
        }

        return {
            init: function(wasmBytes) {
                var imports = {
                    wbg: {
                        __wbindgen_init_externref_table: function() {
                            var refs = exports.__wbindgen_externrefs;
                            var t = refs.grow(4);
                            refs.set(0, undefined);
                            refs.set(t + 0, undefined);
                            refs.set(t + 1, null);
                            refs.set(t + 2, true);
                            refs.set(t + 3, false);
                        }
                    }
                };
                var module = new WebAssembly.Module(wasmBytes);
                var instance = new WebAssembly.Instance(module, imports);
                exports = instance.exports;
                memCache = null;
                if (typeof exports.__wbindgen_start === 'function') {
                    exports.__wbindgen_start();
                }
            },
            calculatePassive: function(headJoints, antennas) {
                if (exports === null) return null;
                var head = passIn(new Float64Array(headJoints));
                var ant  = passIn(new Float64Array(antennas));
                var r = exports.calculate_passive_joints(head[0], head[1], ant[0], ant[1]);
                var out = getOut(r[0], r[1]);
                exports.__wbindgen_free(r[0], r[1] * 8, 8);
                return Array.prototype.slice.call(out);
            }
        };
    })();
    """

    // MARK: - Bytes → Uint8Array

    /// Construct a zero-copy Uint8Array in the JS context backed by a
    /// malloc'd copy of the data. The deallocator hands the buffer
    /// back to free() when JSC GCs the array.
    private static func makeUint8Array(
        from data: Data, in context: JSContext
    ) -> JSValue {
        let count = data.count
        let buffer = malloc(count)!
        data.withUnsafeBytes { srcPtr in
            _ = memcpy(buffer, srcPtr.baseAddress, count)
        }
        var exception: JSValueRef?
        let ref = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef,
            kJSTypedArrayTypeUint8Array,
            buffer,
            count,
            { ptr, _ in free(ptr) },
            nil,
            &exception
        )
        return JSValue(jsValueRef: ref, in: context)
    }
}

enum StewartIKError: Error {
    case shimUnavailable
    case jsException(String)
    case wasmMissing
}
