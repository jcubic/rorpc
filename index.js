import { marked } from 'marked';
import fs from 'fs/promises';
import { gfmHeadingId } from 'marked-gfm-heading-id';

marked.use(gfmHeadingId());

const template = await fs.readFile('./template.html', 'utf8');
const spec = await fs.readFile('SPEC.md', 'utf8');

const html = marked.parse(spec);

console.log(template.replace('{{BODY}}', () => html));
