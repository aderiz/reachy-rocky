"""Rocky brain sidecar — vision-language inference via mlx-vlm.

Default model: Qwen3-VL-4B-Instruct-4bit. Native MLX on Apple Silicon.
The runner exposes:

    chat_stream(messages, tools, image_b64?) -> streams `token` events
        with `delta` text + `tool_call_delta` events, then `done`.

    set_model(name) -> hot-swap the underlying model.

    health() -> { backend, model, vision_cache_size }.
"""
