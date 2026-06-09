cask "magicquit" do
  version "1.4.2"
  sha256 "a196ba698aedee3d7a3040552d85dca1bdebb50e1167d197a5bdf95e28ac4e76"

  url "https://github.com/theghostonline/magicquitv2/releases/download/v#{version}/MagicQuit-#{version}.zip"
  name "MagicQuit"
  desc "Menu bar app that quits inactive apps with app exclusions"
  homepage "https://github.com/theghostonline/magicquitv2"

  auto_updates false
  depends_on macos: :ventura

  app "MagicQuit.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MagicQuit.app"],
                   sudo: false
  end

  zap trash: "~/Library/Preferences/com.MagicQuit.plist"
end
