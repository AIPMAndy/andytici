cask "andytici" do
  version "0.1.0"
  sha256 "875c1f4d8ec02190d1dddfcf9b5503346346255f3d4e070d3ff9d2526d6d81cd"

  url "https://github.com/AIPMAndy/andytici/releases/download/v#{version}/AndyTici-#{version}.dmg"
  name "Andy题词"
  desc "口播创作者提词器（macOS 原生）— 抖音 / 小红书 / 视频号 专用"
  homepage "https://github.com/AIPMAndy/andytici"

  livecheck do
    url :url
    strategy :github_latest_release
  end

  app "Andy题词.app"

  zap trash: [
    "~/Library/Application Support/dev.andy.tici",
    "~/Library/Preferences/dev.andy.tici.plist",
    "~/Library/Caches/dev.andy.tici",
  ]
end