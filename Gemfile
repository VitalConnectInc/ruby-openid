# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

#### IMPORTANT #######################################################
# Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
####################################################### IMPORTANT ####
# Root Gemfile is only for local development only. It is not loaded on CI.
# On CI we only need the gemspecs' dependencies (including development dependencies).
# Exceptions, if any, will be found in gemfiles/*.gemfile

# When depended on directly, these previously stdlib gems,
#   deprecated in Ruby 3.3 & removed in Ruby 3.5
#   make it difficult to build on GA CI with Ruby 2.7 and bundler v2.4.22.
# See: https://github.com/rubygems/rubygems/issues/7178#issuecomment-2372558363
gem "net-http", "~> 0.4", ">= 0.4.1"
gem "uri", "~> 0.13", ">= 0.13.1"
gem "logger", "~> 1.6", ">= 1.6.1"
gem "rexml", "~> 3.3", ">= 3.3.7"

# Specify your gem's dependencies in ruby-openid.gemspec
gemspec

platform :mri do
  # Debugging
  gem "byebug", ">= 11"
end
