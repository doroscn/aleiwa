// 配置
const API_ENDPOINT = 'https://ipinfo.io/json';
const DATA_PATH = './data';

// 初始化
document.addEventListener('DOMContentLoaded', async () => {
    // 设置默认国家代码
    try {
        const response = await fetch(API_ENDPOINT);
        const data = await response.json();
        document.getElementById('countryCode').value = data.country.toLowerCase();
        loadData();
    } catch (error) {
        console.error('Error detecting country:', error);
    }
});

async function loadData() {
    const countryCode = document.getElementById('countryCode').value.trim().toLowerCase();
    
    try {
        // 加载国家元数据
        const [countries, lastChecked] = await Promise.all([
            fetchJson(`${DATA_PATH}/country_map.json`),
            fetchJson(`scripts/state/validation_status.json`)
        ]);

        // 显示国家信息
        const countryInfo = countries[countryCode.toUpperCase()] || 'Country';
        const checkedTime = lastChecked.find(c => c.country_id === countryCode)?.checked_at;
        
        document.getElementById('countryName').textContent = countryInfo;
        document.getElementById('countryCodeDisplay').textContent = countryCode.toUpperCase();
        document.getElementById('lastChecked').textContent = checkedTime ? formatDate(checkedTime) : 'N/A';
        document.getElementById('countryInfo').classList.remove('hidden');

        // 加载ASN和DNS数据
        const [asnData, dnsData] = await Promise.all([
            fetchJson(`asn/country_data/${countryCode}.json`),
            fetchJson(`dnsselect/${countryCode}.json`)
        ]);

        // 处理ASN数据
        const topASN = asnData.Data.slice(0, 10);
        renderTable('#asnTable tbody', topASN, asnRowMapper);
        document.getElementById('asnCount').textContent = asnData.Data.length;
        document.getElementById('viewAllASN').href = `/asn/asn.html?code=${countryCode}`;

        // 处理DNS数据
        renderTable('#dnsTable tbody', dnsData, dnsRowMapper);
        document.getElementById('dnsCount').textContent = dnsData.length;

    } catch (error) {
        console.error('Error loading data:', error);
        alert('Error loading data for this country');
    }
}

// 表格渲染逻辑
function renderTable(selector, data, rowMapper) {
    const tbody = document.querySelector(selector);
    tbody.innerHTML = data.map(rowMapper).join('');
}

// ASN行映射
function asnRowMapper(item) {
    return `
        <tr>
            <td>${item.rank}</td>
            <td>AS${item.AS}</td>
            <td>${item.Description}</td>
            <td>${item['Percent of CC Pop'].toFixed(2)}%</td>
            <td>${item['Percent of Internet'].toFixed(4)}%</td>
        </tr>
    `;
}

// DNS行映射
function dnsRowMapper(item) {
    return `
        <tr>
            <td>${item.ip}</td>
            <td>${item.name || 'N/A'}</td>
            <td>AS${item.as_number}</td>
            <td>${item.as_org}</td>
            <td>${item.country_id}</td>
            <td class="${item.available ? 'available' : 'unavailable'}">
                ${item.available ? '✔' : '✖'}
            </td>
            <td>${formatDate(item.checked_at)}</td>
        </tr>
    `;
}

// 工具函数
async function fetchJson(url) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
    return response.json();
}

function formatDate(isoString) {
    return new Date(isoString).toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
    });
}