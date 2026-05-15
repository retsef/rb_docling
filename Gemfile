# frozen_string_literal: true

source "https://rubygems.org"

# rb_docling dipende da rpdfium e onnxruntime (entrambe wrap FFI/native).
gem "rpdfium",     "~> 0.3"
gem "onnxruntime", "~> 0.11"

# In ambienti dove le gem non sono raggiungibili (offline, allowlist di rete
# restrittiva), si possono caricare entrambe via path locale:
#
#   gem "rpdfium",     path: "../rpdfium"
#   gem "onnxruntime", path: "../onnxruntime-ruby"

group :development do
  gem "rake", "~> 13.0"
end
