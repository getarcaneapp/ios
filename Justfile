set shell := ["bash", "-euo", "pipefail", "-c"]

sources := '"Arcane Mobile" ArcaneWidgets Shared "Arcane MobileTests"'

default:
    @just --list

format:
    nice -n 19 xcrun swift-format format --in-place --recursive --configuration .swift-format {{sources}}

format-check:
    nice -n 19 xcrun swift-format lint --strict --recursive --configuration .swift-format {{sources}}

lint:
    nice -n 19 swiftlint lint --strict --quiet --config .swiftlint.yml

check: format-check lint

analyze build_log:
    nice -n 19 swiftlint analyze --strict --config .swiftlint.yml --compiler-log-path {{quote(build_log)}}
