Pod::Spec.new do |s|
  s.name         = "SwiftyDebug"
  s.version      = "0.1"
  s.summary      = "In-app debugging tool for iOS."
  s.homepage     = "https://github.com/oah2008/SwiftyDebug"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = "Omar Hariri"
  s.platform     = :ios, "15.0"
  s.source       = { :git => "", :tag => s.version.to_s }

  s.source_files = "Sources/**/*.{swift,h,m}"
  s.resources    = "Sources/Resources/**/*"
  s.library      = "sqlite3"

  s.swift_version = "5.9"
end
