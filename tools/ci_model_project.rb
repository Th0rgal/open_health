# Generate a validation-only TORCH Swift target with a stub C bridge, never a release.
require 'yaml'
root = File.expand_path('../apps/ios/OuraApp', __dir__)
spec = YAML.load_file(File.join(root, 'project-ci.yml'))
app = spec.fetch('targets').fetch('OuraApp')
app.fetch('settings').fetch('base')['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'TORCH'
app.fetch('settings').fetch('base')['SWIFT_OBJC_BRIDGING_HEADER'] = 'TorchBridge.h'
%w[EventStore.swift ModelCache.swift SleepStaging.swift ActivityModel.swift CvaModel.swift IllnessModel.swift].each do |path|
  app.fetch('sources') << { 'path' => path }
end
app.fetch('sources') << { 'path' => '../../../tools/ci_model_bridge.c' }
File.write(File.join(root, 'project-model-validation.yml'), YAML.dump(spec))
