import AVFoundation
import Photos
import SwiftUI
import UIKit
import WebKit

// MARK: - JS injected at document start (tiny: dark + ad-hide CSS only)
// Runs before first paint to kill the white flash. Reads display settings
// from localStorage only (dark / hideAds). No credentials, no sign-in.
private let esJSStart = """
(function(){
  function read(k,d){ try{ var v=localStorage.getItem('es_'+k); return v===null?d:v; }catch(e){ return d; } }
  if(read('dark','0')==='1'){
    var el=document.createElement('style'); el.id='es-dark-style';
    el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
    document.documentElement.appendChild(el);
  }
  if(read('hideAds','1')==='1'){
    var el2=document.createElement('style'); el2.id='es-ad-style';
    el2.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
    document.documentElement.appendChild(el2);
  }
})();
"""

// MARK: - JS injected at document end
// Safe features only: dark mode toggle, hide ads toggle, keyword filter,
// fullscreen images, remember scroll position, section navigation.
// NOTE: Enshan has NO sign-in API/button. The daily reward (+1 恩山币)
// is granted by visiting while logged in, so opening the app IS the
// daily visit. No attendance call is made here. Login state lives only
// in the WKWebView system cookie jar; localStorage holds display
// settings only (dark / hideAds / keywords), never any credential.
private let esJSEnd = """
(function(){
  function store(k,v){ try{ localStorage.setItem('es_'+k, v); }catch(e){} }
  function read(k,d){ try{ var v=localStorage.getItem('es_'+k); return v===null?d:v; }catch(e){ return d; } }

  // ---------- 1. Dark mode (toggle; start script already applied the CSS) ----------
  window.__esSetDark = function(on){
    store('dark', on?'1':'0');
    var id='es-dark-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='html{filter:invert(1) hue-rotate(180deg);background:#0f0f0f !important;} img,video,iframe,svg{filter:invert(1) hue-rotate(180deg);}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('dark','0')==='1') { window.__esSetDark(true); }

  // ---------- 2. Hide ads / promo blocks (toggle; start script already applied the CSS) ----------
  window.__esSetHideAds = function(on){
    store('hideAds', on?'1':'0');
    var id='es-ad-style', el=document.getElementById(id);
    if(on){
      if(!el){
        el=document.createElement('style'); el.id=id;
        el.textContent='[class*="ad-"],[id*="ad-"],[class*="advert"],[class*="sponsor"],[class*="promo-banner"]{display:none !important;}';
        document.documentElement.appendChild(el);
      }
    } else if(el){ el.remove(); }
  };
  if (read('hideAds','1')==='1') { window.__esSetHideAds(true); }

  // ---------- 3. Keyword filter (hide thread rows whose title contains a keyword) ----------
  // Discuz thread links look like thread-123-1-1.html or forum.php?mod=viewthread.
  window.__esSetKeywords = function(csv){
    store('keywords', csv||'');
    applyKeywords();
  };
  function applyKeywords(){
    var csv = read('keywords','');
    var kws = csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
    var rows = document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
    rows.forEach(function(a){
      var row = a.closest('li, article, div, tr');
      if(!row) return;
      var txt = (a.textContent||'');
      var hit = kws.some(function(k){ return txt.indexOf(k) !== -1; });
      row.style.display = hit ? 'none' : '';
    });
  }
  window.__esApplyKeywords = applyKeywords;
  applyKeywords();
  new MutationObserver(function(){ applyKeywords(); applyRead(); applyNotes(); applyBlacklist(); applyHighlight(); }).observe(document.documentElement, {childList:true, subtree:true});

  // ---------- 4. Fullscreen image viewer ----------
  document.addEventListener('click', function(e){
    var img = e.target.closest ? e.target.closest('img') : null;
    if(!img || !img.src) return;
    if(img.closest('a')) return;
    var ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.92);z-index:999999;display:flex;align-items:center;justify-content:center;';
    var im=document.createElement('img');
    im.src=img.src; im.style.cssText='max-width:96vw;max-height:92vh;object-fit:contain;';
    ov.appendChild(im);
    ov.addEventListener('click', function(){ ov.remove(); });
    document.body.appendChild(ov);
  }, true);

  // ---------- 5. Remember scroll position (per URL) ----------
  var saveTimer=null;
  function savePos(){
    try{ sessionStorage.setItem('es_pos_'+location.pathname, String(window.scrollY)); }catch(e){}
  }
  function restorePos(){
    try{
      var y=parseInt(sessionStorage.getItem('es_pos_'+location.pathname)||'0',10);
      if(y>200){ setTimeout(function(){ window.scrollTo(0,y); }, 350); }
    }catch(e){}
  }
  window.addEventListener('scroll', function(){
    if(saveTimer) clearTimeout(saveTimer);
    saveTimer=setTimeout(savePos, 400);
  }, {passive:true});
  window.addEventListener('pagehide', savePos);
  restorePos();

  // ---------- 6. Section navigation (tap a section name in the native picker) ----------
  // Exact board-name match first, then substring match (board titles on
  // the homepage carry brand/type suffixes, e.g. "小米/红米无线路由器…").
  window.__esGoSection = function(name){
    var links = Array.prototype.slice.call(document.querySelectorAll('a'));
    var hit = links.find(function(a){
      var t=(a.textContent||'').trim();
      return t===name && a.getAttribute('href') && a.getAttribute('href').indexOf('/')===0;
    });
    if(!hit){
      hit = links.find(function(a){
        var t=(a.textContent||'').trim();
        return t.indexOf(name)!==-1 && a.getAttribute('href') && a.getAttribute('href').indexOf('forum')!==-1;
      });
    }
    if(hit){ hit.click(); return true; }
    return false;
  };

  // ---------- 7. Back to top ----------
  window.__esTop = function(){ window.scrollTo({top:0, behavior:'smooth'}); };

  // ---------- 9. Read markers (dim threads already opened) ----------
  // Thread IDs are stored in localStorage only (display state, no credentials).
  function getRead(){
    try{ var a=JSON.parse(localStorage.getItem('es_read')||'[]'); return Array.isArray(a)?a:[]; }
    catch(e){ return []; }
  }
  function markRead(tid){
    try{
      var a=getRead();
      if(a.indexOf(tid)===-1){ a.push(tid); if(a.length>500) a=a.slice(-500); localStorage.setItem('es_read', JSON.stringify(a)); }
    }catch(e){}
  }
  function threadIdFromHref(h){
    if(!h) return null;
    var m=h.match(/thread-(\\d+)/);
    if(m) return m[1];
    m=h.match(/[?&]tid=(\\d+)/);
    return m?m[1]:null;
  }
  function applyRead(){
    var read=getRead(); if(!read.length) return;
    var links=document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
    links.forEach(function(a){
      var tid=threadIdFromHref(a.getAttribute('href'));
      if(tid && read.indexOf(tid)!==-1){
        var row=a.closest('li, article, div, tr');
        if(row) row.style.opacity='0.45';
      }
    });
  }
  window.__esClearRead=function(){
    try{ localStorage.removeItem('es_read'); }catch(e){}
    var links=document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]');
    links.forEach(function(a){
      var row=a.closest('li, article, div, tr');
      if(row) row.style.opacity='';
    });
  };
  document.addEventListener('click', function(e){
    var a=e.target.closest?e.target.closest('a[href*="thread-"], a[href*="mod=viewthread"]'):null;
    if(!a) return;
    var tid=threadIdFromHref(a.getAttribute('href'));
    if(tid) markRead(tid);
  }, true);
  applyRead();

  // ---------- 10. Infinite scroll on list pages ----------
  // Discuz list pages: next-page link is a.nxt (fallback: "下一页" in .pg).
  // Fetch it, take its thread rows (tbody[id^="normalthread_"]) and append
  // to this page's table. Read-only fetch, no posting.
  var esNextLoading=false, esNextURL=null;
  function findNextURL(doc){
    var a=doc.querySelector('a.nxt[href]');
    if(!a){
      var links=doc.querySelectorAll('.pg a[href]');
      for(var i=0;i<links.length;i++){
        if((links[i].textContent||'').indexOf('下一页')!==-1){ a=links[i]; break; }
      }
    }
    if(!a) return null;
    var h=a.getAttribute('href');
    if(!h || h.indexOf('javascript')===0) return null;
    try{ return new URL(h, doc.baseURI).href; }catch(e){ return null; }
  }
  function isListPage(){
    var u=location.href;
    if(u.indexOf('viewthread')!==-1) return false;
    return u.indexOf('forumdisplay')!==-1 || /forum-\\d+/.test(u) || /\\/forum\\/$/.test(u);
  }
  function esMaybeLoadNext(){
    if(esNextLoading) return;
    if(!isListPage()) return;
    if(window.innerHeight + window.scrollY < document.body.scrollHeight - 700) return;
    if(!esNextURL){
      esNextURL=findNextURL(document);
      if(!esNextURL || esNextURL===location.href) return;
    }
    esNextLoading=true;
    fetch(esNextURL, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
      var doc=new DOMParser().parseFromString(html,'text/html');
      var rows=doc.querySelectorAll('tbody[id^="normalthread_"]');
      var table=document.querySelector('#threadlisttableid');
      var target=null;
      if(table){ target=table.querySelector('tbody') || table; }
      if(rows.length && target){
        rows.forEach(function(tr){ target.appendChild(document.importNode(tr, true)); });
        applyKeywords(); applyRead(); foldLongPosts(); decorateCodeBlocks(); applyNotes(); applyBlacklist(); applyHighlight();
      }
      esNextURL=findNextURL(doc);
      if(esNextURL===location.href) esNextURL=null;
      esNextLoading=false;
    }).catch(function(){ esNextLoading=false; });
  }
  window.addEventListener('scroll', function(){ esMaybeLoadNext(); }, {passive:true});

  // ---------- 11. Only show OP (只看楼主) ----------
  window.__esOnlyOP=function(on){
    if(on){
      var links=Array.prototype.slice.call(document.querySelectorAll('a'));
      var hit=links.find(function(a){ return (a.textContent||'').indexOf('只看该作者')!==-1 && a.getAttribute('href'); });
      if(hit){ hit.click(); return true; }
      return false;
    } else {
      try{
        var u=new URL(location.href);
        if(u.searchParams.has('authorid')){
          u.searchParams.delete('authorid');
          location.href=u.href;
          return true;
        }
      }catch(e){}
      return false;
    }
  };

  // ---------- 12. Fold long posts ----------
  function foldLongPosts(){
    var posts=document.querySelectorAll('td.t_f');
    posts.forEach(function(td){
      if(td.getAttribute('data-es-folded')) return;
      td.setAttribute('data-es-folded','1');
      var txt=td.textContent||'';
      if(txt.length<1200) return;
      var wrap=document.createElement('div');
      wrap.style.cssText='max-height:340px;overflow:hidden;position:relative;';
      while(td.firstChild){ wrap.appendChild(td.firstChild); }
      td.appendChild(wrap);
      var btn=document.createElement('div');
      btn.textContent='展开全文';
      btn.style.cssText='text-align:center;padding:8px 0;color:#2f80ed;cursor:pointer;font-size:14px;';
      btn.addEventListener('click', function(e){
        e.stopPropagation();
        wrap.style.maxHeight='none'; wrap.style.overflow='visible';
        btn.remove();
      });
      td.appendChild(btn);
    });
  }
  foldLongPosts();

  // ---------- 13. Thread preview on long-press (list pages) ----------
  // Long-press a thread title (600ms) -> fetch its first post, show the
  // first ~300 chars in a card. Tap outside to close, "打开帖子" to open.
  var esPressTimer=null, esPressFired=false;
  function esClosePreview(){
    var ov=document.getElementById('es-preview-ov');
    if(ov) ov.remove();
  }
  function esShowPreview(a){
    var url=a.getAttribute('href');
    var title=(a.textContent||'').trim();
    fetch(url, {credentials:'include'}).then(function(r){ return r.text(); }).then(function(html){
      var doc=new DOMParser().parseFromString(html,'text/html');
      var first=doc.querySelector('td.t_f');
      var txt=first?first.textContent.replace(/\\s+/g,' ').trim():'';
      if(txt.length>300) txt=txt.slice(0,300)+'…';
      var ov=document.createElement('div');
      ov.id='es-preview-ov';
      ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:999999;display:flex;align-items:flex-end;justify-content:center;';
      var card=document.createElement('div');
      card.style.cssText='background:#fff;color:#111;border-radius:16px 16px 0 0;padding:18px;max-height:62vh;overflow:auto;width:100%;';
      var h=document.createElement('div');
      h.textContent=title;
      h.style.cssText='font-weight:700;font-size:16px;margin-bottom:8px;';
      var p=document.createElement('p');
      p.textContent=txt||'（暂无预览）';
      p.style.cssText='font-size:14px;line-height:1.6;margin:0 0 14px 0;';
      var open=document.createElement('button');
      open.textContent='打开帖子';
      open.style.cssText='width:100%;padding:12px;border:none;border-radius:10px;background:#2f80ed;color:#fff;font-size:16px;';
      open.addEventListener('click', function(){ location.href=url; });
      card.appendChild(h); card.appendChild(p); card.appendChild(open);
      ov.appendChild(card);
      ov.addEventListener('click', function(e){ if(e.target===ov) esClosePreview(); });
      document.body.appendChild(ov);
    }).catch(function(){});
  }
  document.addEventListener('touchstart', function(e){
    var a=e.target.closest?e.target.closest('a[href*="thread-"], a[href*="mod=viewthread"]'):null;
    if(!a || !isListPage()) return;
    esPressTimer=setTimeout(function(){
      esPressTimer=null;
      esPressFired=true;
      setTimeout(function(){ esPressFired=false; }, 2000);
      esShowPreview(a);
    }, 600);
  }, {passive:true});
  document.addEventListener('touchend', function(){ if(esPressTimer){ clearTimeout(esPressTimer); esPressTimer=null; } }, {passive:true});
  document.addEventListener('touchmove', function(){ if(esPressTimer){ clearTimeout(esPressTimer); esPressTimer=null; } }, {passive:true});
  // Swallow the click that follows a long-press so we don't navigate
  // (except clicks inside the preview card itself).
  document.addEventListener('click', function(e){
    if(e.target.closest && e.target.closest('#es-preview-ov')) return;
    if(esPressFired){ e.preventDefault(); e.stopPropagation(); esPressFired=false; }
  }, true);

  // ---------- 14. Export current thread as data (native builds Markdown) ----------
  window.__esExportMD=function(){
    var posts=[];
    var postDivs=document.querySelectorAll('div[id^="post_"]');
    postDivs.forEach(function(div){
      var authorEl=div.querySelector('.authi .xw1, .pls .authi a, .authi a');
      var timeEl=div.querySelector('.authi em');
      var tf=div.querySelector('td.t_f');
      if(!tf) return;
      var imgs=[];
      tf.querySelectorAll('img').forEach(function(im){
        var s=im.getAttribute('zoomfile')||im.getAttribute('file')||im.getAttribute('src');
        if(s && s.indexOf('http')===0 && imgs.indexOf(s)===-1) imgs.push(s);
      });
      posts.push({
        author: authorEl?authorEl.textContent.trim():'',
        time: timeEl?timeEl.textContent.trim():'',
        text: tf.innerText||'',
        images: imgs
      });
    });
    return JSON.stringify({title: document.title, url: location.href, posts: posts});
  };

  // ---------- 15. Thread text for read-aloud ----------
  window.__esThreadText=function(){
    var parts=[];
    document.querySelectorAll('td.t_f').forEach(function(td){
      var t=(td.innerText||'').trim();
      if(t) parts.push(t);
    });
    var text=parts.join('\\n\\n');
    if(text.length>20000) text=text.slice(0,20000);
    return JSON.stringify({title: document.title, text: text});
  };

  // ---------- 16. Image URLs on this page ----------
  window.__esPageImages=function(){
    var out=[];
    document.querySelectorAll('td.t_f img').forEach(function(im){
      var s=im.getAttribute('zoomfile')||im.getAttribute('file')||im.getAttribute('src');
      if(!s || s.indexOf('http')!==0) return;
      if(s.indexOf('static/image/')!==-1) return;
      if(out.indexOf(s)===-1) out.push(s);
    });
    return JSON.stringify(out);
  };

  // ---------- 18. User notes + blacklist (Batch B) ----------
  // Notes: username -> short note, shown as a small yellow strip next to
  // the username on thread pages. Blacklist: usernames hidden in lists
  // and replies. Both stored in localStorage only (display state).
  function getNotes(){
    try{ var o=JSON.parse(localStorage.getItem('es_notes')||'{}'); return (o&&typeof o==='object')?o:{}; }
    catch(e){ return {}; }
  }
  function getBlacklist(){
    try{ var a=JSON.parse(localStorage.getItem('es_blacklist')||'[]'); return Array.isArray(a)?a:[]; }
    catch(e){ return []; }
  }
  window.__esSetNotes=function(json){
    try{ localStorage.setItem('es_notes', json); }catch(e){}
    applyNotes();
  };
  window.__esSetBlacklist=function(json){
    try{ localStorage.setItem('es_blacklist', json); }catch(e){}
    applyBlacklist();
  };
  function applyNotes(){
    var notes=getNotes();
    var names=Object.keys(notes);
    if(!names.length) return;
    document.querySelectorAll('.authi .xw1, .pls .authi a, .authi a').forEach(function(a){
      var name=(a.textContent||'').trim();
      var note=notes[name];
      if(!note) return;
      if(a.parentElement && a.parentElement.querySelector('.es-note')) return;
      var s=document.createElement('span');
      s.className='es-note';
      s.textContent=' '+note;
      s.style.cssText='background:#fff3bf;color:#7a5b00;font-size:11px;padding:1px 5px;border-radius:4px;margin-left:4px;white-space:nowrap;';
      a.insertAdjacentElement('afterend', s);
    });
  }
  function applyBlacklist(){
    var bl=getBlacklist();
    if(!bl.length) return;
    document.querySelectorAll('div[id^="post_"]').forEach(function(div){
      var a=div.querySelector('.authi .xw1, .pls .authi a, .authi a');
      var name=a?(a.textContent||'').trim():'';
      if(name && bl.indexOf(name)!==-1) div.style.display='none';
    });
    document.querySelectorAll('td.by cite a').forEach(function(a){
      var name=(a.textContent||'').trim();
      if(name && bl.indexOf(name)!==-1){
        var row=a.closest('tr');
        if(row) row.style.display='none';
      }
    });
  }

  // ---------- 19. Keyword highlight (Batch B) ----------
  // Separate group from the filter words: matched titles/usernames get a
  // yellow background instead of being hidden.
  window.__esSetHighlight=function(csv){
    store('highlight', csv||'');
    applyHighlight();
  };
  function escRe(s){ return s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'); }
  function highlightTextNodes(el, kws){
    var nodes=[];
    el.childNodes.forEach(function(n){ if(n.nodeType===3) nodes.push(n); });
    nodes.forEach(function(n){
      var txt=n.nodeValue;
      var re=new RegExp('('+kws.map(escRe).join('|')+')', 'g');
      if(!re.test(txt)) return;
      re.lastIndex=0;
      var frag=document.createDocumentFragment();
      var last=0, m;
      while((m=re.exec(txt))!==null){
        if(m.index>last) frag.appendChild(document.createTextNode(txt.slice(last, m.index)));
        var sp=document.createElement('span');
        sp.textContent=m[0];
        sp.style.cssText='background:#ffe066;color:#111;border-radius:2px;';
        frag.appendChild(sp);
        last=m.index+m[0].length;
      }
      if(last<txt.length) frag.appendChild(document.createTextNode(txt.slice(last)));
      n.parentNode.replaceChild(frag, n);
    });
  }
  function applyHighlight(){
    var csv=read('highlight','');
    var kws=csv.split(',').map(function(s){ return s.trim(); }).filter(function(s){ return s.length>0; });
    if(!kws.length) return;
    document.querySelectorAll('a[href*="thread-"], a[href*="mod=viewthread"]').forEach(function(a){
      if(a.getAttribute('data-es-hl')) return;
      a.setAttribute('data-es-hl','1');
      highlightTextNodes(a, kws);
    });
    document.querySelectorAll('.authi a, td.by cite a').forEach(function(a){
      if(a.getAttribute('data-es-hl')) return;
      a.setAttribute('data-es-hl','1');
      highlightTextNodes(a, kws);
    });
  }

  // ---------- 20. Insert a reply template into the reply box (Batch B) ----------
  // The user taps a template in the app; we only INSERT the text, the
  // user submits manually. Reply-box selector is a fallback chain:
  // #reply_content -> textarea[name="content"] -> textarea in a reply
  // form -> any textarea. NOTE: the real reply-box HTML was never captured
  // while logged in, so this chain is best-effort; if tapping a template
  // does nothing while logged in, the selector needs adjusting to the
  // live page.
  window.__esInsertTemplate=function(text){
    var box=document.querySelector('#reply_content')
      || document.querySelector('textarea[name="content"]')
      || document.querySelector('form[action*="post.php"] textarea, form[action*="forum.php"] textarea')
      || document.querySelector('textarea');
    if(!box) return false;
    try{
      var setter=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      setter.call(box, (box.value ? box.value + '\\n' : '') + text);
    }catch(e){ box.value=(box.value ? box.value + '\\n' : '') + text; }
    box.dispatchEvent(new Event('input', {bubbles:true}));
    box.dispatchEvent(new Event('change', {bubbles:true}));
    box.focus();
    box.scrollIntoView({block:'center'});
    return true;
  };

  // ---------- 21. Code block copy button + basic highlight (Batch B) ----------
  // Single-pass tokenizer: comment / string / number / keyword, so the
  // inserted spans are never re-matched by a later pass.
  // NOTE: every backslash below is doubled -- Swift string literals
  // reject \\d \\s \\b \\n \\/ etc., and a single \\n would become a real
  // newline inside a JS string literal and break the whole script.
  function escHtml(s){
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  function highlightCode(code){
    var re=/(\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)|("(?:[^"\\\\\\n]|\\\\.)*"|'(?:[^'\\\\\\n]|\\\\.)*')|(\\b\\d+(?:\\.\\d+)?\\b)|\\b(function|var|let|const|if|else|for|while|return|class|import|from|new|try|catch|switch|case|break|continue|do|typeof|void|delete|in|of|this|true|false|null|undefined|echo|print|public|private|protected|static|int|string|bool|float|double|char|long|short|byte|def|end|then|module|require|include|extends|implements|interface|namespace|use|fn|pub|struct|impl|enum|match|mut|ref|where|async|await|yield|pass|lambda|with|as|assert|del|except|finally|global|is|not|and|or|raise)\\b/g;
    var out='', last=0, m;
    while((m=re.exec(code))!==null){
      out+=escHtml(code.slice(last, m.index));
      var cls=m[1]?'#6a9955':(m[2]?'#ce9178':(m[3]?'#b5cea8':'#569cd6'));
      out+='<span style="color:'+cls+'">'+escHtml(m[0])+'</span>';
      last=m.index+m[0].length;
    }
    out+=escHtml(code.slice(last));
    return out;
  }
  function addCopyButton(el, code){
    var btn=document.createElement('button');
    btn.textContent='复制';
    btn.style.cssText='position:absolute;top:6px;right:6px;font-size:12px;padding:3px 8px;border:1px solid #ccc;border-radius:6px;background:#fff;color:#333;z-index:5;';
    btn.addEventListener('click', function(e){
      e.stopPropagation();
      var done=function(){ btn.textContent='已复制'; setTimeout(function(){ btn.textContent='复制'; }, 1200); };
      if(navigator.clipboard && navigator.clipboard.writeText){
        navigator.clipboard.writeText(code).then(done, function(){ fallbackCopy(code); done(); });
      } else { fallbackCopy(code); done(); }
    });
    if(getComputedStyle(el).position==='static') el.style.position='relative';
    el.appendChild(btn);
  }
  function fallbackCopy(text){
    var ta=document.createElement('textarea');
    ta.value=text; ta.style.cssText='position:fixed;opacity:0;';
    document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); }catch(e){}
    ta.remove();
  }
  function decorateCodeBlocks(){
    document.querySelectorAll('pre').forEach(function(pre){
      if(pre.getAttribute('data-es-code')) return;
      pre.setAttribute('data-es-code','1');
      var code=pre.textContent||'';
      if(!code.trim()) return;
      pre.innerHTML=highlightCode(code);
      addCopyButton(pre, code);
    });
    document.querySelectorAll('.blockcode').forEach(function(el){
      if(el.getAttribute('data-es-code')) return;
      el.setAttribute('data-es-code','1');
      if(el.querySelector('pre')) return;
      var code=el.textContent||'';
      if(!code.trim()) return;
      addCopyButton(el, code);
    });
  }

  // ---------- 22. Site search (Batch B) ----------
  // Uses the site's own header search form when present (it carries the
  // formhash Discuz requires); otherwise navigates to the search page.
  // NOTE: search.php could not be verified end-to-end from outside the
  // site (datacenter IPs get a bot-check page), so if the form is missing
  // and the direct URL lands on the search form, the user just taps
  // search once more there.
  window.__esSearch=function(q){
    var input=document.querySelector('#scbar_txt, input[name="srchtxt"]');
    var form=input?input.closest('form'):null;
    if(input && form){
      input.value=q;
      form.submit();
      return true;
    }
    location.href='https://www.right.com.cn/search.php?mod=forum&srchtxt='+encodeURIComponent(q);
    return true;
  };

  // ---------- 24. Translation helpers (Batch B) ----------
  // Native does the translating (MyMemory free or user BYOK); JS only
  // extracts text. No network call from JS.
  window.__esSelectedText=function(){
    try{ return (window.getSelection()||'').toString(); }catch(e){ return ''; }
  };
  window.__esPageText=function(){
    var parts=[];
    document.querySelectorAll('td.t_f').forEach(function(td){
      var t=(td.innerText||'').trim();
      if(t) parts.push(t);
    });
    return JSON.stringify({title: document.title, parts: parts});
  };

  // ---------- 17. Re-run hook (called from native didFinish) ----------
  window.__esAfterLoad = function(){ applyKeywords(); applyRead(); applyNotes(); applyBlacklist(); applyHighlight(); foldLongPosts(); decorateCodeBlocks(); restorePos(); };
})();
"""

// MARK: - Batch B models
struct TemplateGroup: Codable, Identifiable {
    var id = UUID()
    var name: String
    var templates: [String]
}

struct TranslationSegment: Identifiable {
    let id = UUID()
    let original: String
    let translation: String
}

// MARK: - Model
final class BrowserModel: NSObject, ObservableObject {
    weak var webView: WKWebView?
    @Published var isDark = false
    @Published var fontScale: CGFloat = 1.0
    @Published var hideAds = true
    @Published var keywords = ""
    @Published var canGoBack = false
    // v2 batch A: thread-page state + notices
    @Published var isThreadPage = false
    @Published var onlyOP = false
    @Published var isSpeaking = false
    @Published var notice: String?
    // v2 batch B: notes / blacklist / highlight / templates / search / translation
    @Published var notes: [String: String] = [:]
    @Published var blacklist: [String] = []
    @Published var highlightWords = ""
    @Published var templateGroups: [TemplateGroup] = [TemplateGroup(name: "常用", templates: ["感谢分享！", "学习了，谢谢楼主。", "马克一下，慢慢看。", "已收藏，谢谢分享。"])]
    @Published var searchHistory: [String] = []
    @Published var useBYOK = false
    @Published var translateKey = ""
    @Published var translateBaseURL = "https://openrouter.ai/api/v1"
    @Published var translateModel = "deepseek/deepseek-chat"
    @Published var translationSegments: [TranslationSegment]?
    @Published var showTranslation = false
    @Published var isTranslating = false
    private var speech = AVSpeechSynthesizer()

    // Trailing slash: /forum without it 301-redirects once (wasted round trip).
    let homeURL = URL(string: "https://www.right.com.cn/forum/")!
    let sections = ["OpenWrt","小米","拆机","TP-LINK","华为","中兴","CPE","腾达","华硕","H3C","斐讯","360"]

    init() {
        super.init()
        // Settings read synchronously here so the webview can load at once
        // without waiting for the view's onAppear.
        isDark = UserDefaults.standard.bool(forKey: "es_dark")
        hideAds = UserDefaults.standard.object(forKey: "es_hideAds") as? Bool ?? true
        keywords = UserDefaults.standard.string(forKey: "es_keywords") ?? ""
        let fs = UserDefaults.standard.double(forKey: "es_fontScale")
        if fs > 0 { fontScale = CGFloat(fs) }
        if let data = UserDefaults.standard.data(forKey: "es_notes"),
           let d = try? JSONDecoder().decode([String: String].self, from: data) { notes = d }
        if let data = UserDefaults.standard.data(forKey: "es_blacklist"),
           let d = try? JSONDecoder().decode([String].self, from: data) { blacklist = d }
        highlightWords = UserDefaults.standard.string(forKey: "es_highlight") ?? ""
        if let data = UserDefaults.standard.data(forKey: "es_templates"),
           let d = try? JSONDecoder().decode([TemplateGroup].self, from: data), !d.isEmpty { templateGroups = d }
        if let data = UserDefaults.standard.data(forKey: "es_searchHistory"),
           let d = try? JSONDecoder().decode([String].self, from: data) { searchHistory = d }
        useBYOK = UserDefaults.standard.bool(forKey: "es_useBYOK")
        translateKey = UserDefaults.standard.string(forKey: "es_translateKey") ?? ""
        translateBaseURL = UserDefaults.standard.string(forKey: "es_translateBaseURL") ?? "https://openrouter.ai/api/v1"
        translateModel = UserDefaults.standard.string(forKey: "es_translateModel") ?? "deepseek/deepseek-chat"
        speech.delegate = self
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__esTop && window.__esTop();", completionHandler: nil)
    }
    func goSection(_ name: String) {
        webView?.evaluateJavaScript("window.__esGoSection && window.__esGoSection('\(name)');") { _, _ in }
    }
    func setDark(_ on: Bool) {
        isDark = on
        UserDefaults.standard.set(on, forKey: "es_dark")
        webView?.evaluateJavaScript("window.__esSetDark && window.__esSetDark(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setFontScale(_ s: CGFloat) {
        fontScale = s
        UserDefaults.standard.set(Double(s), forKey: "es_fontScale")
        webView?.pageZoom = s
    }
    func setHideAds(_ on: Bool) {
        hideAds = on
        UserDefaults.standard.set(on, forKey: "es_hideAds")
        webView?.evaluateJavaScript("window.__esSetHideAds && window.__esSetHideAds(\(on ? "true" : "false"));", completionHandler: nil)
    }
    func setKeywords(_ s: String) {
        keywords = s
        UserDefaults.standard.set(s, forKey: "es_keywords")
        let esc = s.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("window.__esSetKeywords && window.__esSetKeywords('\(esc)');", completionHandler: nil)
    }

    // MARK: - v2 batch A: safe thread tools (read-only or user-triggered)

    func toggleOnlyOP() {
        let on = !onlyOP
        webView?.evaluateJavaScript("window.__esOnlyOP && window.__esOnlyOP(\(on ? "true" : "false"));") { [weak self] result, _ in
            if (result as? Bool) == true { self?.onlyOP = on }
        }
    }

    func clearReadHistory() {
        webView?.evaluateJavaScript("window.__esClearRead && window.__esClearRead();", completionHandler: nil)
        notice = "已读记录已清空"
    }

    func exportMarkdown() {
        webView?.evaluateJavaScript("window.__esExportMD && window.__esExportMD();") { [weak self] result, _ in
            guard let self = self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let posts = obj["posts"] as? [[String: Any]], !posts.isEmpty else {
                self?.notice = "这个页面没有可导出的帖子内容"
                return
            }
            var md = "# \(obj["title"] as? String ?? "帖子")\n\n"
            md += "来源：\(obj["url"] as? String ?? "")\n\n"
            for p in posts {
                let author = p["author"] as? String ?? ""
                let time = p["time"] as? String ?? ""
                md += "## \(author) \(time)\n\n"
                md += "\(p["text"] as? String ?? "")\n\n"
                if let imgs = p["images"] as? [String] {
                    for u in imgs { md += "![](\(u))\n\n" }
                }
            }
            self.shareText(md, filename: "thread.md")
        }
    }

    func exportPDF() {
        webView?.createPDF { [weak self] result in
            switch result {
            case .success(let data):
                self?.shareData(data, filename: "thread.pdf")
            case .failure:
                self?.notice = "生成 PDF 失败"
            }
        }
    }

    func savePageImages() {
        webView?.evaluateJavaScript("window.__esPageImages && window.__esPageImages();") { [weak self] result, _ in
            guard let self = self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let urls = try? JSONSerialization.jsonObject(with: data) as? [String], !urls.isEmpty else {
                self?.notice = "这个页面没有可保存的图片"
                return
            }
            self.saveImages(urls: urls)
        }
    }

    private func saveImages(urls: [String]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.notice = "没有相册权限，请在系统设置里允许" }
                return
            }
            let group = DispatchGroup()
            var images: [UIImage] = []
            let lock = NSLock()
            for u in urls {
                guard let url = URL(string: u) else { continue }
                group.enter()
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    defer { group.leave() }
                    if let data = data, let image = UIImage(data: data) {
                        lock.lock(); images.append(image); lock.unlock()
                    }
                }.resume()
            }
            group.notify(queue: .main) {
                guard !images.isEmpty else {
                    self?.notice = "图片下载失败"
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    for img in images { PHAssetChangeRequest.creationRequestForAsset(from: img) }
                }) { success, _ in
                    DispatchQueue.main.async {
                        self?.notice = success ? "已保存 \(images.count) 张图片到相册" : "保存到相册失败"
                    }
                }
            }
        }
    }

    func toggleSpeech() {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        webView?.evaluateJavaScript("window.__esThreadText && window.__esThreadText();") { [weak self] result, _ in
            guard let self = self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty else {
                self?.notice = "这个页面没有可朗读的帖子正文"
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            self.speech.speak(utterance)
            self.isSpeaking = true
        }
    }

    // MARK: - v2 batch B: notes / blacklist / highlight / templates / search / share / translate

    // Escape a Swift string for embedding in a JS single-quoted literal.
    private func jsString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func pushNotesToJS() {
        guard let data = try? JSONEncoder().encode(notes),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__esSetNotes && window.__esSetNotes('\(jsString(json))');", completionHandler: nil)
    }
    private func pushBlacklistToJS() {
        guard let data = try? JSONEncoder().encode(blacklist),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__esSetBlacklist && window.__esSetBlacklist('\(jsString(json))');", completionHandler: nil)
    }
    private func pushHighlightToJS() {
        webView?.evaluateJavaScript("window.__esSetHighlight && window.__esSetHighlight('\(jsString(highlightWords))');", completionHandler: nil)
    }
    func pushBatchBSettingsToJS() {
        pushNotesToJS(); pushBlacklistToJS(); pushHighlightToJS()
    }

    func saveNotes() {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: "es_notes")
        }
        pushNotesToJS()
    }
    func addNote(user: String, note: String) {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        notes[u] = note
        saveNotes()
    }
    func removeNote(user: String) { notes.removeValue(forKey: user); saveNotes() }
    func saveBlacklist() {
        if let data = try? JSONEncoder().encode(blacklist) {
            UserDefaults.standard.set(data, forKey: "es_blacklist")
        }
        pushBlacklistToJS()
    }
    func addBlacklist(user: String) {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !blacklist.contains(u) else { return }
        blacklist.append(u)
        saveBlacklist()
    }
    func removeBlacklist(user: String) { blacklist.removeAll { $0 == user }; saveBlacklist() }

    func setHighlightWords(_ s: String) {
        highlightWords = s
        UserDefaults.standard.set(s, forKey: "es_highlight")
        pushHighlightToJS()
    }

    func saveTemplates() {
        if let data = try? JSONEncoder().encode(templateGroups) {
            UserDefaults.standard.set(data, forKey: "es_templates")
        }
    }
    func addTemplate(groupId: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = templateGroups.firstIndex(where: { $0.id == groupId }) else { return }
        templateGroups[i].templates.append(t)
        saveTemplates()
    }
    func removeTemplate(groupId: UUID, index: Int) {
        guard let i = templateGroups.firstIndex(where: { $0.id == groupId }),
              templateGroups[i].templates.indices.contains(index) else { return }
        templateGroups[i].templates.remove(at: index)
        saveTemplates()
    }
    func addTemplateGroup(name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        templateGroups.append(TemplateGroup(name: n, templates: []))
        saveTemplates()
    }
    func removeTemplateGroup(id: UUID) {
        templateGroups.removeAll { $0.id == id }
        if templateGroups.isEmpty {
            templateGroups = [TemplateGroup(name: "常用", templates: [])]
        }
        saveTemplates()
    }

    func insertTemplate(_ text: String) {
        webView?.evaluateJavaScript("window.__esInsertTemplate && window.__esInsertTemplate('\(jsString(text))');") { [weak self] result, _ in
            if (result as? Bool) != true {
                self?.notice = "没找到回复框，请确认已登录并打开了回复框"
            }
        }
    }

    func searchSite(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchHistory.removeAll { $0 == query }
        searchHistory.insert(query, at: 0)
        if searchHistory.count > 10 { searchHistory = Array(searchHistory.prefix(10)) }
        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: "es_searchHistory")
        }
        webView?.evaluateJavaScript("window.__esSearch && window.__esSearch('\(jsString(query))');", completionHandler: nil)
    }

    func shareCurrentPage() {
        guard let url = webView?.url else { return }
        let title = webView?.title ?? ""
        shareItems(["\(title)\n\(url.absoluteString)", url])
    }

    func saveTranslationSettings() {
        UserDefaults.standard.set(useBYOK, forKey: "es_useBYOK")
        UserDefaults.standard.set(translateKey, forKey: "es_translateKey")
        UserDefaults.standard.set(translateBaseURL, forKey: "es_translateBaseURL")
        UserDefaults.standard.set(translateModel, forKey: "es_translateModel")
    }

    // MARK: Translation (MyMemory free default; BYOK only if the user filled a key)

    func translateSelection() {
        webView?.evaluateJavaScript("window.__esSelectedText && window.__esSelectedText();") { [weak self] result, _ in
            guard let self = self, let text = result as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self?.notice = "请先在帖子里选中一段文字，再点翻译"
                return
            }
            self.runTranslation(texts: [text])
        }
    }

    func translatePage() {
        webView?.evaluateJavaScript("window.__esPageText && window.__esPageText();") { [weak self] result, _ in
            guard let self = self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parts = obj["parts"] as? [String], !parts.isEmpty else {
                self?.notice = "这个页面没有可翻译的帖子正文"
                return
            }
            self.runTranslation(texts: parts)
        }
    }

    private func runTranslation(texts: [String]) {
        let limit = (useBYOK && !translateKey.isEmpty) ? 8000 : 2500
        var kept: [String] = []
        var total = 0
        for t in texts {
            if total >= limit { break }
            let room = limit - total
            if t.count <= room { kept.append(t); total += t.count }
            else { kept.append(String(t.prefix(room))); total = limit }
        }
        guard !kept.isEmpty else { notice = "没有可翻译的内容"; return }
        isTranslating = true
        translationSegments = nil
        Task {
            var segments: [TranslationSegment] = []
            for t in kept {
                let tr = await self.translateText(t)
                segments.append(TranslationSegment(original: t, translation: tr))
            }
            await MainActor.run {
                self.translationSegments = segments
                self.isTranslating = false
                self.showTranslation = true
            }
        }
    }

    private func translateText(_ text: String) async -> String {
        let cjkCount = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let isChinese = cjkCount * 2 > text.count
        if useBYOK, !translateKey.isEmpty {
            return await translateBYOK(text, target: isChinese ? "English" : "Chinese")
        }
        return await translateMyMemory(text, from: isChinese ? "zh-CN" : "en", to: isChinese ? "en" : "zh-CN")
    }

    // MyMemory free API: no key, max ~500 bytes per request; we chunk at 450 UTF-8 bytes.
    private func translateMyMemory(_ text: String, from: String, to: String) async -> String {
        var out: [String] = []
        for chunk in chunkForMyMemory(text) {
            var comps = URLComponents(string: "https://api.mymemory.translated.net/get")!
            comps.queryItems = [
                URLQueryItem(name: "q", value: chunk),
                URLQueryItem(name: "langpair", value: "\(from)|\(to)")
            ]
            guard let url = comps.url else { out.append(chunk); continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rd = obj["responseData"] as? [String: Any],
                   let t = rd["translatedText"] as? String, !t.isEmpty,
                   t != "QUERY LENGTH LIMIT EXCEEDED", t != "INVALID TARGET LANGUAGE" {
                    out.append(t)
                } else { out.append(chunk) }
            } catch { out.append(chunk) }
        }
        return out.joined()
    }

    private func chunkForMyMemory(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var parts: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if "。！？；.!?;\n".contains(ch) { parts.append(buf); buf = "" }
        }
        if !buf.isEmpty { parts.append(buf) }
        for p in parts {
            if (current + p).utf8.count <= 450 {
                current += p
            } else {
                if !current.isEmpty { chunks.append(current); current = "" }
                var rest = p
                while rest.utf8.count > 450 {
                    var cut = ""
                    for ch in rest {
                        if (cut + String(ch)).utf8.count > 450 { break }
                        cut.append(ch)
                    }
                    if cut.isEmpty { cut = String(rest.prefix(1)) }
                    chunks.append(cut)
                    rest = String(rest.dropFirst(cut.count))
                }
                current = rest
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func translateBYOK(_ text: String, target: String) async -> String {
        let base = translateBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { return text }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(translateKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": translateModel,
            "messages": [
                ["role": "system", "content": "Translate the following text into \(target). Return only the translation, no explanation."],
                ["role": "user", "content": text]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String, !content.isEmpty {
                return content
            }
        } catch {}
        return text
    }

    // MARK: - Share sheet helpers

    private func shareText(_ text: String, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        shareItems([url])
    }

    private func shareData(_ data: Data, filename: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        shareItems([url])
    }

    private func shareItems(_ items: [Any]) {
        // Small delay so the settings sheet finishes dismissing first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
            var vc = root
            while let presented = vc.presentedViewController { vc = presented }
            let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let pop = ac.popoverPresentationController {
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
            vc.present(ac, animated: true)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension BrowserModel: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
                .ignoresSafeArea(edges: .top)
            BottomBar(model: model, showSections: $showSections, showSettings: $showSettings)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $model.showTranslation) {
            TranslationSheet(segments: model.translationSegments ?? [])
        }
        .alert("提示", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

// MARK: - WebView
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Explicit default (persistent) data store: cache + cookies persist
        // across launches, so repeat opens reuse cache and the Cloudflare
        // cf_clearance cookie instead of re-verifying. Never clear it,
        // never use .nonPersistent(), never reload ignoring local cache.
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Split injection: tiny CSS-only script at document start (kills
        // white flash), the rest at document end. forMainFrameOnly: true
        // keeps the scripts out of every ad iframe.
        let startScript = WKUserScript(source: esJSStart, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let endScript = WKUserScript(source: esJSEnd, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(startScript)
        config.userContentController.addUserScript(endScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        if model.fontScale != 1.0 { webView.pageZoom = model.fontScale }
        // Load immediately: settings were already read in the model init.
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
            if let url = webView.url?.absoluteString {
                model.isThreadPage = url.contains("thread-") || url.contains("mod=viewthread")
                model.onlyOP = url.contains("authorid")
            }
            // Re-apply keyword filter + scroll restore now the page is done.
            webView.evaluateJavaScript("window.__esAfterLoad && window.__esAfterLoad();", completionHandler: nil)
            // Push Batch B display settings (notes / blacklist / highlight) into the page.
            model.pushBatchBSettingsToJS()
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            model.canGoBack = webView.canGoBack
        }
    }
}

// MARK: - Bottom bar (comfortable proportions, smooth)
// Enshan has no sign-in button: opening the app IS the daily visit.
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 4) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: model.isDark ? "moon.fill" : "moon", label: "深色") {
                model.setDark(!model.isDark)
            }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "gearshape", label: "设置") { showSettings = true }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Section picker sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func doSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        model.searchSite(q)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("搜索恩山帖子", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { doSearch() }
                        Button("搜索") { doSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    if !model.searchHistory.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.searchHistory, id: \.self) { h in
                                    Button(h) {
                                        searchText = h
                                        model.searchSite(h)
                                        dismiss()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.sections, id: \.self) { name in
                        Button {
                            model.goSection(name)
                            dismiss()
                        } label: {
                            Text(name)
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                Text("点分区名即跳到对应版块；若某一名没跳过去，说明首页该版块标题写法不同，改在设置里报给我即可。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            .navigationTitle("分区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsText = ""
    @State private var noteUser = ""
    @State private var noteText = ""
    @State private var blacklistUser = ""
    @State private var newGroupName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("每日访问") {
                    Text("恩山没有签到按钮：登录后每天打开 App 就算一次访问（+1 恩山币）。登录一次即可，登录态会一直保留；若掉登录，重新登录一次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("阅读") {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Stepper("", value: Binding(
                            get: { model.fontScale },
                            set: { model.setFontScale($0) }
                        ), in: 0.85...1.35, step: 0.05)
                        Text(String(format: "%.0f%%", model.fontScale * 100))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle("深色模式", isOn: Binding(
                        get: { model.isDark },
                        set: { model.setDark($0) }
                    ))
                    Toggle("隐藏广告与推广位", isOn: Binding(
                        get: { model.hideAds },
                        set: { model.setHideAds($0) }
                    ))
                }
                Section("屏蔽关键词") {
                    TextField("多个关键词用英文逗号隔开", text: $keywordsText)
                        .onChange(of: keywordsText) { model.setKeywords($0) }
                    Text("包含这些词的帖子标题会被隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("高亮关键词，英文逗号隔开", text: Binding(
                        get: { model.highlightWords },
                        set: { model.setHighlightWords($0) }
                    ))
                    HStack {
                        Button("复制导出高亮词") {
                            UIPasteboard.general.string = model.highlightWords
                            model.notice = "高亮词已复制到剪贴板"
                        }
                        Spacer()
                        Button("从剪贴板导入") {
                            if let s = UIPasteboard.general.string, !s.isEmpty {
                                model.setHighlightWords(s)
                                model.notice = "已从剪贴板导入高亮词"
                            } else {
                                model.notice = "剪贴板里没有文字"
                            }
                        }
                    }
                    Text("命中的帖子标题和用户名会标黄显示，和屏蔽关键词是两组不同的词。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("清空已读记录") { model.clearReadHistory() }
                }
                Section("用户备注与黑名单") {
                    HStack {
                        TextField("用户名", text: $noteUser)
                        TextField("备注", text: $noteText)
                        Button("添加") {
                            model.addNote(user: noteUser, note: noteText)
                            noteUser = ""; noteText = ""
                        }
                    }
                    ForEach(model.notes.sorted(by: { $0.key < $1.key }), id: \.key) { user, note in
                        HStack {
                            Text(user).fontWeight(.medium)
                            Text(note).foregroundStyle(.secondary)
                            Spacer()
                            Button("删除") { model.removeNote(user: user) }
                                .foregroundStyle(.red)
                        }
                    }
                    HStack {
                        TextField("用户名", text: $blacklistUser)
                        Button("加入黑名单") {
                            model.addBlacklist(user: blacklistUser)
                            blacklistUser = ""
                        }
                    }
                    ForEach(model.blacklist, id: \.self) { user in
                        HStack {
                            Text(user)
                            Spacer()
                            Button("移出") { model.removeBlacklist(user: user) }
                                .foregroundStyle(.red)
                        }
                    }
                    Text("备注会以小黄条显示在帖子页该用户名旁边；黑名单用户在列表和回复里都会隐藏。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("快捷回复模板") {
                    ForEach(model.templateGroups) { group in
                        TemplateGroupEditor(model: model, group: group)
                    }
                    HStack {
                        TextField("新分组名", text: $newGroupName)
                        Button("新增分组") {
                            model.addTemplateGroup(name: newGroupName)
                            newGroupName = ""
                        }
                    }
                    Text("在帖子里点模板，文字只会插进回复框，发送必须你自己点。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("翻译") {
                    Toggle("使用自己的 API Key（BYOK）", isOn: Binding(
                        get: { model.useBYOK },
                        set: { model.useBYOK = $0; model.saveTranslationSettings() }
                    ))
                    if model.useBYOK {
                        SecureField("API Key", text: Binding(
                            get: { model.translateKey },
                            set: { model.translateKey = $0; model.saveTranslationSettings() }
                        ))
                        TextField("Base URL", text: Binding(
                            get: { model.translateBaseURL },
                            set: { model.translateBaseURL = $0; model.saveTranslationSettings() }
                        ))
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        TextField("模型", text: Binding(
                            get: { model.translateModel },
                            set: { model.translateModel = $0; model.saveTranslationSettings() }
                        ))
                        .autocapitalization(.none)
                    }
                    Text("默认用免费 MyMemory 翻译，无需配置；打开 BYOK 并填好 Key 后走你自己的模型。翻译只在你点翻译时才调用接口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("帖子工具") {
                    if model.isThreadPage {
                        Toggle("只看楼主", isOn: Binding(
                            get: { model.onlyOP },
                            set: { _ in model.toggleOnlyOP() }
                        ))
                        Button("导出 Markdown（分享）") { model.exportMarkdown(); dismiss() }
                        Button("转 PDF（分享）") { model.exportPDF(); dismiss() }
                        Button("保存本页图片到相册") { model.savePageImages(); dismiss() }
                        Button(model.isSpeaking ? "停止朗读" : "朗读帖子") { model.toggleSpeech(); dismiss() }
                        Button("分享帖子") { model.shareCurrentPage(); dismiss() }
                        Button(model.isTranslating ? "正在翻译…" : "翻译选中文字") { model.translateSelection(); dismiss() }
                            .disabled(model.isTranslating)
                        Button(model.isTranslating ? "正在翻译…" : "翻译本页（双语对照）") { model.translatePage(); dismiss() }
                            .disabled(model.isTranslating)
                        Text("快捷回复（点一下插进回复框，发送要你自己点）：")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(model.templateGroups) { group in
                            ForEach(group.templates, id: \.self) { t in
                                Button(t) { model.insertTemplate(t); dismiss() }
                            }
                        }
                    } else {
                        Text("打开一个帖子后，这里会出现只看楼主、导出 Markdown、转 PDF、保存图片、朗读等工具。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("刷新页面") { model.reload(); dismiss() }
                    Button("回到首页") { model.goHome(); dismiss() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { keywordsText = model.keywords }
            .alert("提示", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )) {
                Button("好", role: .cancel) { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Template group editor (Batch B)
struct TemplateGroupEditor: View {
    @ObservedObject var model: BrowserModel
    let group: TemplateGroup
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.name).fontWeight(.semibold)
                Spacer()
                Button("删除分组") { model.removeTemplateGroup(id: group.id) }
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            ForEach(Array(group.templates.enumerated()), id: \.offset) { idx, t in
                HStack {
                    Text(t)
                    Spacer()
                    Button("删除") { model.removeTemplate(groupId: group.id, index: idx) }
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            HStack {
                TextField("新模板", text: $draft)
                Button("添加") {
                    model.addTemplate(groupId: group.id, text: draft)
                    draft = ""
                }
            }
        }
    }
}

// MARK: - Translation sheet (Batch B, bilingual: original above, translation below in blue)
struct TranslationSheet: View {
    let segments: [TranslationSegment]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if segments.isEmpty {
                        Text("没有翻译结果")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(segments) { seg in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(seg.original)
                                .font(.body)
                            Text(seg.translation)
                                .font(.body)
                                .foregroundStyle(.blue)
                        }
                        Divider()
                    }
                }
                .padding(16)
            }
            .navigationTitle("翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
