enum LlamaChatRole { user }

enum GpuBackend { cpu }

class LlamaBackend {}

class LlamaChatMessage {
  LlamaChatMessage.fromText({required LlamaChatRole role, required String text});
}

class GenerationParams {
  const GenerationParams({
    required int maxTokens,
    required double temp,
    required int topK,
    required double topP,
    required double penalty,
    required bool reusePromptPrefix,
  });
}

class ModelParams {
  const ModelParams({required int gpuLayers, required GpuBackend preferredBackend});
}

class LlamaDelta {
  final String? content;
  const LlamaDelta(this.content);
}

class LlamaChoice {
  final LlamaDelta delta;
  const LlamaChoice(this.delta);
}

class LlamaChunk {
  final List<LlamaChoice> choices;
  const LlamaChunk(this.choices);
}

class LlamaEngine {
  LlamaEngine(LlamaBackend backend);

  Future<void> loadModel(String path, {required ModelParams modelParams}) async {
    throw UnsupportedError('On-device translation is unavailable on Android 5.1.1');
  }

  Stream<LlamaChunk> create(
    List<LlamaChatMessage> messages, {
    required GenerationParams params,
    required bool enableThinking,
    String? sourceLangCode,
    String? targetLangCode,
  }) => const Stream<LlamaChunk>.empty();

  Future<void> dispose() async {}
}
