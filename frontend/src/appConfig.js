export const TYPE_FILTERS = [
  { value: 'all', label: '全部' },
  { value: 'image', label: '图片' },
  { value: 'video', label: '视频' },
  { value: 'favorite', label: '♥ 收藏' },
]

export const SPEC_FILTERS = [
  { value: 'all', label: '全部规格' },
  { value: '4k', label: '4K+ 超清' },
  { value: 'landscape', label: '横屏宽幅' },
  { value: 'portrait', label: '竖屏立绘' },
  { value: 'audio', label: '♪ 含配乐' },
  { value: 'layered', label: '✦ 可拆图层' },
]

export const COLOR_BUCKETS = [
  { value: 'dark', label: '曜石暗色', swatch: '#23232f' },
  { value: 'light', label: '纯净浅白', swatch: '#f1f1f7' },
  { value: 'blue', label: '冰川冷蓝', swatch: '#3b82f6' },
  { value: 'purple', label: '赛博紫粉', swatch: '#a855f7' },
  { value: 'green', label: '森系青绿', swatch: '#10b981' },
  { value: 'warm', label: '落日暖色', swatch: '#f97316' },
]

export const SORT_MODES = [
  { value: 'default', label: '默认排序' },
  { value: 'size', label: '占用空间优先' },
  { value: 'resolution', label: '分辨率优先' },
  { value: 'title', label: '名称 A–Z' },
]

export const RATING_FILTERS = [
  { value: 'all', label: '全部分级' },
  { value: 'everyone', label: '全年龄安全' },
  { value: 'mature', label: '擦边 / 限制级' },
]

export function parseResolutionDimensions(resolution) {
  if (!resolution) return { width: 0, height: 0 }
  const match = String(resolution).match(/(\d+)\s*[×xX]\s*(\d+)/)
  return match
    ? { width: Number(match[1]) || 0, height: Number(match[2]) || 0 }
    : { width: 0, height: 0 }
}

export function parseResolutionPixels(resolution) {
  const { width, height } = parseResolutionDimensions(resolution)
  return width * height
}

export function parseResolutionAspect(resolution) {
  if (!resolution) return '16 / 9'
  const match = String(resolution).match(/(\d+)\s*[×xX]\s*(\d+)/)
  if (!match) return '16 / 9'
  const w = Number(match[1])
  const h = Number(match[2])
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return '16 / 9'
  return `${w} / ${h}`
}

export const THEME_MODES = [
  { value: 'light', label: '浅色' },
  { value: 'dark', label: '暗色' },
]

export const CARD_MODES = [
  { value: 'magnet', label: '磁铁' },
  { value: 'tilt', label: '全息' },
]

export const IMAGE_EXPORT_FORMATS = [
  { value: 'original', label: '原格式', tag: '无损' },
  { value: 'png', label: 'PNG', tag: '无损' },
  { value: 'jpg', label: 'JPG', tag: '轻量' },
  { value: 'webp', label: 'WebP', tag: '高压缩' },
]

export const VIDEO_EXPORT_FORMATS = [
  { value: 'original', label: '原格式', tag: '直拷' },
  { value: 'mp4', label: 'MP4', tag: 'H.264' },
  { value: 'webm', label: 'WebM', tag: 'VP9' },
  { value: 'gif', label: 'GIF', tag: '动图' },
]

export const NAVIGATION_STYLES = [
  { value: 'island', label: '胶囊工具岛 + 居中弹窗（默认）' },
  { value: 'drawer', label: '分立按钮 + 右侧抽屉' },
]

export const THEME_COLORS = [
  '#7c3aed',
  '#2563eb',
  '#00bfe8',
  '#ff1744',
  '#ff2d8d',
  '#ffd500',
]

export const SELECTION_BORDER_MODES = [
  { value: 'snake', label: '环绕流光' },
  { value: 'orbit', label: '旋转边框' },
]

export const HARDWARE_ACCELERATION_MODES = [
  {
    value: 'gpu',
    label: '独立显卡（GPU）',
    description: '默认强制调用独立显卡进行界面渲染、视频解码与特效合成。',
  },
  {
    value: 'cpu',
    label: 'CPU 软件渲染',
    description: '关闭 GPU 加速与显存占用，仅在显卡驱动异常时用于兼容兜底。',
  },
]

export const APP_INFO = {
  name: 'WallPull',
  version: '1.0.2',
  author: 'Xiaonan',
  license: 'GNU GPL-3.0',
  repoUrl: 'https://github.com/XiaonanXY/WallPull',
  issuesUrl: 'https://github.com/XiaonanXY/WallPull/issues',
  releasesUrl: 'https://github.com/XiaonanXY/WallPull/releases',
  feedbackUrl: 'https://qm.qq.com/q/aYrBqaDlDi',
  feedbackGroupNumber: '471426180',
}

function parseSemverTuple(raw) {
  const cleaned = String(raw || '')
    .trim()
    .replace(/^[vV]/, '')
    .split(/[-+]/)[0]
  if (!cleaned) return null
  const [majStr, minStr = '0', patchStr = '0'] = cleaned.split('.')
  const major = Number.parseInt(majStr, 10)
  const minor = Number.parseInt(minStr, 10)
  const patch = Number.parseInt(patchStr, 10)
  if ([major, minor, patch].some(n => Number.isNaN(n) || n < 0)) return null
  return [major, minor, patch]
}

export function isNewerVersion(latest, current) {
  const l = parseSemverTuple(latest)
  const c = parseSemverTuple(current)
  if (!l || !c) return false
  for (let i = 0; i < 3; i += 1) {
    if (l[i] > c[i]) return true
    if (l[i] < c[i]) return false
  }
  return false
}

export const DEFAULT_CARD_SIZE = 230

export const DEFAULT_SETTINGS = {
  workshopRoot: '',
  exportDirectory: '',
  parseScenes: true,
  cardMode: 'tilt',
  sparkSizePercent: 100,
  sparkColor: '#7c3aed',
  selectionBorderMode: 'snake',
  hardwareAccelerationMode: 'gpu',
  themeMode: 'light',
  navigationStyle: 'island',
  toolboxLayout: 'bento',
  closeToTray: false,
  showArchivedBadge: false,
  favoriteIds: [],
  localsendEnabled: true,
  localsendAlias: 'WallPull PC',
  mediaFilter: 'all',
  specFilter: 'all',
  ratingFilter: 'all',
  sortBy: 'default',
  colorFilter: null,
}

export const MOCK_WALLPAPERS = Array.from({ length: 18 }, (_, index) => ({
  id: `demo-${index + 1}`,
  workshopId: `${1000000001 + index}`,
  title: index === 0 ? '极光海岸 4K 动态壁纸' : `创意工坊示例壁纸 ${index + 1}`,
  type: index % 3 === 2 ? 'video' : 'image',
  originalType: index % 2 === 0 ? 'scene' : index % 3 === 2 ? 'video' : 'image',
  previewUrl: '/demo-preview.svg',
  mediaUrl: '/demo-preview.svg',
  resolution: index === 0 ? '3840 × 2160' : '1920 × 1080',
  duration: index % 3 === 2 ? '0:24' : null,
  fileSize: 12_500_000,
  folderSize: 45_200_000,
  hasAudio: index === 0,
  audioTracks: index === 0 ? [{ name: 'Theme BGM', url: '', size: 4_200_000 }] : [],
  contentRating: 'Everyone',
  tags: ['Landscape'],
  customizableCount: index === 0 ? 3 : 0,
  isArchivedOffline: index === 1,
}))

export function createRequestId() {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`
}

export function formatBytes(value) {
  if (!Number.isFinite(value) || value <= 0) return '未知大小'
  const units = ['B', 'KB', 'MB', 'GB']
  let size = value
  let unit = 0
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024
    unit += 1
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`
}

export function isValidHexColor(value) {
  return /^#[0-9a-f]{6}$/i.test(value)
}

export function readableTextColor(hex) {
  const channels = [1, 3, 5].map(offset => {
    const channel = Number.parseInt(hex.slice(offset, offset + 2), 16) / 255
    return channel <= 0.04045
      ? channel / 12.92
      : ((channel + 0.055) / 1.055) ** 2.4
  })
  const luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
  const whiteContrast = 1.05 / (luminance + 0.05)
  const darkContrast = (luminance + 0.05) / 0.051
  return darkContrast >= whiteContrast ? '#18181b' : '#ffffff'
}

export function readableAccentInk(hex, isDark = false) {
  let channels = [1, 3, 5].map(offset =>
    Number.parseInt(hex.slice(offset, offset + 2), 16))

  const relativeLuminance = rgb => {
    const linear = rgb.map(value => {
      const channel = value / 255
      return channel <= 0.04045
        ? channel / 12.92
        : ((channel + 0.055) / 1.055) ** 2.4
    })
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
  }

  if (isDark) {
    const darkBgLum = 0.025
    let guard = 0
    while ((relativeLuminance(channels) + 0.05) / (darkBgLum + 0.05) < 4.8 && guard < 18) {
      channels = channels.map(value => Math.min(255, Math.round(value + (255 - value) * 0.16)))
      guard += 1
    }
    return `#${channels.map(value => value.toString(16).padStart(2, '0')).join('')}`
  }

  let guard = 0
  while (1.05 / (relativeLuminance(channels) + 0.05) < 4.5 && guard < 18) {
    channels = channels.map(value => Math.max(0, Math.round(value * 0.88)))
    guard += 1
  }

  return `#${channels.map(value => value.toString(16).padStart(2, '0')).join('')}`
}
