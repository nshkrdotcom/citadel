# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-10

### Added

- Publish the first Weld-generated Citadel runtime artifact from the canonical
  workspace package graph.
- Include durable authority persistence, model and tool-effect governance, and
  runtime configuration sources in the public artifact.

### Changed

- Declare `ground_plane_contracts` as an explicit, publishable dependency of
  the trace bridge and generated package instead of leaking a sibling path
  dependency into the release boundary.
