const fs = require('fs');
const path = require('path');

const domain = 'https://www.aleiwa.com';
const today = new Date().toISOString().split('T')[0];

const countryMap = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../data/country_map.json'), 'utf8')
);

const blogPosts = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../blog/posts.json'), 'utf8')
);

const outDir = path.join(__dirname, '../');

/* helper */
function url(loc, lastmod = today, priority = '0.8') {
  return `
  <url>
    <loc>${domain}${loc}</loc>
    <lastmod>${lastmod}</lastmod>
    <changefreq>weekly</changefreq>
    <priority>${priority}</priority>
  </url>`;
}

/* ========== Static Pages ========== */
const staticPages = [
  '/',
  '/index.html',
  '/dns.html',
  '/topisps.html',
  '/about.html',
  '/privacy.html',
  '/blog/index.html'
];

const sitemapPages = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${staticPages.map(p => url(p, today, '0.6')).join('\n')}
</urlset>`;

fs.writeFileSync(path.join(outDir, 'sitemap-pages.xml'), sitemapPages);

/* ========== ASN Pages ========== */
const sitemapASN = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${Object.keys(countryMap).map(code =>
  url(`/asn/${code}.html`, today, '0.8')
).join('\n')}
</urlset>`;

fs.writeFileSync(path.join(outDir, 'sitemap-asn.xml'), sitemapASN);

/* ========== DNS Pages ========== */
const sitemapDNS = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${Object.keys(countryMap).map(code =>
  url(`/nameserver/${code}.html`, today, '0.8')
).join('\n')}
</urlset>`;

fs.writeFileSync(path.join(outDir, 'sitemap-dns.xml'), sitemapDNS);

/* ========== Blog Pages (NEW) ========== */
const sitemapBlog = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${blogPosts.map(post =>
  url(
    post.url,
    post.date || today,
    '0.9'
  )
).join('\n')}
</urlset>`;

fs.writeFileSync(path.join(outDir, 'sitemap-blog.xml'), sitemapBlog);

/* ========== Sitemap Index ========== */
const sitemapIndex = `<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap>
    <loc>${domain}/sitemap-pages.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${domain}/sitemap-asn.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${domain}/sitemap-dns.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${domain}/sitemap-blog.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
</sitemapindex>`;

fs.writeFileSync(path.join(outDir, 'sitemap.xml'), sitemapIndex);

console.log('🎉 All sitemaps generated (pages / asn / dns / blog)');
