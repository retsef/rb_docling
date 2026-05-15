# frozen_string_literal: true

module RbDocling
  module Models
    # Carica un modello ONNX da un percorso, con cache singleton per processo.
    class Loader
      @sessions = {}
      @mutex = Mutex.new

      class << self
        attr_reader :sessions, :mutex

        def session(path)
          @mutex.synchronize do
            @sessions[path] ||= begin
              raise Error, "Modello non trovato: #{path}" unless File.exist?(path)
              OnnxRuntime::InferenceSession.new(path)
            end
          end
        end

        def session_inputs(path)
          session(path).inputs
        end

        def session_outputs(path)
          session(path).outputs
        end

        def reset!
          @mutex.synchronize { @sessions.clear }
        end
      end
    end
  end
end
