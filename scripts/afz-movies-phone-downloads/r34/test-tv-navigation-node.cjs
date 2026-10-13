const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const elements=[], listeners=[], styles=[];
const document={activeElement:null,head:{appendChild:s=>styles.push(s)},createElement:()=>({}),addEventListener:(type,fn)=>listeners.push(fn),querySelectorAll:selector=>selector==='[data-afz-focus]'?elements.filter(e=>e.dataset.afzFocus):elements};
function el(id,x,y,tag='A',hidden=false){const e={id,tagName:tag,dataset:{},tabIndex:0,disabled:false,getAttribute:()=>null,getClientRects:()=>hidden?[]:[{}],getBoundingClientRect:()=>({x,y,width:160,height:tag==='BUTTON'?48:180}),removeAttribute:()=>delete e.dataset.afzFocus,focus:()=>document.activeElement=e,scrollIntoView:()=>{},click:()=>e.clicked=true};elements.push(e);return e;}
const nav=el('nav',20,20,'BUTTON');
const a=el('a',20,100),b=el('b',200,100),c=el('c',380,100),d=el('d',20,310),e=el('e',200,310),f=el('f',380,310),query=el('query',20,520,'INPUT'),hidden=el('hidden',100,100,'BUTTON',true);
const context=vm.createContext({window:{location:{}},document,getComputedStyle:()=>({visibility:'visible'})});
const script=fs.readFileSync(process.argv[2] || __dirname+'/seerr-tv.js','utf8');vm.runInContext(script,context);
let results=[];
function press(key){const event={key,prevented:false,preventDefault(){this.prevented=true}};listeners.forEach(fn=>fn(event));return event;}
function check(label,id){assert.equal(document.activeElement.id,id);results.push(label);}
a.focus();press('ArrowRight');check('right across poster row','b');press('ArrowDown');check('down keeps column','e');press('ArrowLeft');check('left across second row','d');press('ArrowUp');check('up keeps column','a');press('Enter');assert(a.clicked);results.push('Enter activates focused poster');query.focus();assert(!press('ArrowLeft').prevented);results.push('input editing retains native keys');vm.runInContext(script,context);assert.equal(listeners.length,1);assert.equal(styles.length,1);results.push('reinjection does not duplicate handlers or styling');nav.focus();press('ArrowUp');assert.equal(context.window.location.href,'afz-seerr://toolbar');results.push('top boundary returns to native toolbar');a.focus();press('ArrowRight');assert.equal(elements.filter(x=>x.dataset.afzFocus).length,1);results.push('one visible focus indicator');
console.log(JSON.stringify({status:'passed',environment:'Node VM with deterministic DOM geometry; not a browser/device test',checks:results.length,results},null,2));
