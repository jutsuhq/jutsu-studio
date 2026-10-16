# Template for the cask in the owner's tap. scripts/update-cask.sh rewrites version and sha256 for each release.
cask "jutsu-studio" do
  version "0.1.0"
  sha256 "dfe79dfbfc9e7383298f8bd3d9000002c0c2c00f5362752e860b1e73462cd57b"

  url "https://github.com/jutsuhq/jutsu-studio/releases/download/v#{version}/Jutsu-Studio-#{version}.dmg"
  name "Jutsu Studio"
  desc "Unofficial desktop app for Higgsfield video and image generation"
  homepage "https://github.com/jutsuhq/jutsu-studio"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Jutsu Studio.app"

  zap trash: [
    "~/Library/Application Scripts/com.jutsustudio.JutsuStudio",
    "~/Library/Containers/com.jutsustudio.JutsuStudio",
  ]
end
