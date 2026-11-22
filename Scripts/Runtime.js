const ProxyHost = "localhost";
const ProxyPort = 8000;
const ProxyAddress = `http://${ProxyHost}:${ProxyPort}`;

function RewriteUrl(url) {
  return url.replace(/^(https?:\/\/.+)$/, `${ProxyAddress}/$1`);
}
