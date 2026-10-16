# Template for the cask in the owner's tap. scripts/update-cask.sh rewrites version and sha256 for each release.
cask "jutsu-studio" do
  version "0.1.1"
  sha256 "3a9d58b82d33d7cbb824ce23df84a3630933a58b97fe1368dfc40415f1e63f8f"

  url "https://github.com/jutsuhq/jutsu-studio/releases/download/v#{version}/Jutsu-Studio-#{version}.dmg"
  name "Jutsu Studio"
  desc "Unofficial desktop app for Higgsfield video and image generation"
  homepage "https://github.com/jutsuhq/jutsu-studio"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle updates the app itself; `brew upgrade` leaves it alone unless run with --greedy.
  auto_updates true
  depends_on macos: :sonoma

  app "Jutsu Studio.app"

  zap trash: [
    "~/Library/Application Scripts/com.jutsustudio.JutsuStudio",
    "~/Library/Containers/com.jutsustudio.JutsuStudio",
  ]
end
