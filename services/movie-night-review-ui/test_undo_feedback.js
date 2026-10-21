const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const file = require('path').join(__dirname, 'candidate', 'screen.js');
const source = fs.readFileSync(file, 'utf8');
const func = source.match(/async function dislike\(movie\)\{[\s\S]*?\n\}/);
assert(func, 'dislike handler not found');
async function exercise(feedback, expected) {
  let writes = [], callback = null;
  const context = {
    reviewWrite: async (path, value) => {writes.push({path,value});return true;},
    toast: (message,label,action) => {assert.equal(label,'Undo');callback=action;}
  };
  vm.createContext(context);
  vm.runInContext(func[0]+';globalThis.dislike=dislike;',context);
  await context.dislike({id:'tt9876543',name:'Fixture Movie',feedback});
  assert.equal(writes.length,1);
  assert.equal(writes[0].value.value,'dislike');
  assert(callback,'Undo button callback absent');
  await callback();
  assert.equal(writes.length,2);
  assert.equal(writes[1].value.value,expected);
  console.log('UNDO '+feedback+' -> '+expected+': PASS');
}
(async () => {
  await exercise('like','like');
  await exercise('clear','clear');
  console.log('UNDO_FEEDBACK_TEST_PASS');
})().catch(err=>{console.error(err);process.exit(1);});
