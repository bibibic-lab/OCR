/**
 * GitHub repo 의 docs 링크 빌더 (gh repo: bibibic-lab/OCR).
 * 환경변수 NEXT_PUBLIC_GITHUB_DOCS_BASE 로 override 가능.
 */
export function githubDocUrl(relativePath: string): string {
  const base =
    process.env.NEXT_PUBLIC_GITHUB_DOCS_BASE ||
    "https://github.com/bibibic-lab/OCR/blob/main";
  // relativePath 가 이미 #anchor 포함일 수 있고, 절대경로 시작 슬래시 정규화.
  const clean = relativePath.startsWith("/") ? relativePath.slice(1) : relativePath;
  return `${base}/${clean}`;
}
