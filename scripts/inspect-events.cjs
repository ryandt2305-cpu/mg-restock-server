const fs = require('fs');
const path = require('path');

const file = path.join(__dirname, '../data/events.json');
if (!fs.existsSync(file)) {
  console.log('events.json not found');
  process.exit(0);
}
const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
const sample = raw.slice(0, 5);
console.log(JSON.stringify(sample, null, 2));
