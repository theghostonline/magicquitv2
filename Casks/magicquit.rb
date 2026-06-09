cask "magicquit" do
  version "1.4.1"
  sha256 "acd091dcde3100a732d6fca8f1825a9baf771bace753c02a5e4c5e3899cec29a"

  url "https://github.com/theghostonline/magicquit/releases/download/v#{version}/MagicQuit-#{version}.zip",
      verified: "github.com/theghostonline/magicquit/"
  name "MagicQuit"
  desc "Menu bar app that quits inactive apps with app exclusions"
  homepage "https://github.com/theghostonline/magicquit"

  auto_updates false
  depends_on macos: :ventura

  no_quarantine true

  app "MagicQuit.app"

  zap trash: "~/Library/Preferences/com.MagicQuit.plist"
end
