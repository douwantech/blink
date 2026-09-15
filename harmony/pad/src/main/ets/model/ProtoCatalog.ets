////////////////////////////////////////////////////////////////////////////////
//
// ProtoCatalog — prototype.douwantech.com 原型目录（浏览器侧栏「原型」那一面）
//
// 站点首页（douwantech/prototype 仓库 site/index.html）的结构：
//   <section class="group"> … <h2>分区名</h2> …
//     <a class="item" data-updated="YYYY-MM-DD" href="/xxx/yyy.html">
//       <h3>标题<span class="upd">MM-DD</span></h3><p>描述</p> …
//     </a>
//   </section>
// 首页只挑了部分条目，各分区页（/ai-printer/ 等）收录全、日期准，所以两层都拉再合并。
// 站点整站 Basic Auth，账密存本机 ui_prefs（protoUser / protoPass）。
// 拉到的目录缓存在 filesDir/proto_index.json，没网也能显示上次的列表。
//
////////////////////////////////////////////////////////////////////////////////

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';

export const PROTO_HOST: string = 'prototype.douwantech.com';
export const PROTO_ORIGIN: string = 'https://' + PROTO_HOST;

export interface ProtoItem {
  section: string;
  url: string;
  title: string;
  desc: string;
  updated: string;   // YYYY-MM-DD，可能为空
}

export interface ProtoCache {
  fetchedAt: number;
  sections: string[];
  items: ProtoItem[];
}

export type ProtoFetchResult = 'ok' | 'noauth' | 'error';

interface ProtoPage {
  code: number;
  body: string;
}

interface ProtoSectionLink {
  section: string;
  href: string;
}

interface ProtoParsed {
  sections: string[];
  links: ProtoSectionLink[];
  items: ProtoItem[];
}

export class ProtoCatalog {
  static load(path: string): ProtoCache | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const c = JSON.parse(fs.readTextSync(path)) as ProtoCache;
      return (c.items !== undefined && c.sections !== undefined) ? c : null;
    } catch (e) {
      return null;
    }
  }

  static save(path: string, c: ProtoCache): void {
    try {
      const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(c));
      fs.closeSync(f);
    } catch (e) {
    }
  }

  /// 首页拿分区顺序；再并发拉各分区页（/ai-printer/ 等）——分区页收录更全、日期更准
  /// （首页只挑了一部分，而且 data-updated 被部署时的 checkout 时间刷成同一天）。
  static fetch(user: string, pass: string, done: (r: ProtoFetchResult, c: ProtoCache | null, msg: string) => void): void {
    const header: Record<string, string> = {};
    if (user.length > 0) {
      header['Authorization'] = 'Basic ' + new util.Base64Helper()
        .encodeToStringSync(new util.TextEncoder().encodeInto(user + ':' + pass));
    }
    ProtoCatalog.get('/', header).then((top: ProtoPage) => {
      if (top.code === 401) {
        done('noauth', null, user.length > 0 ? '账号或密码不对' : '需要原型站账号');
        return;
      }
      if (top.code !== 200) {
        done('error', null, 'HTTP ' + top.code);
        return;
      }
      const home: ProtoParsed = ProtoCatalog.parse(top.body);
      if (home.items.length === 0) {
        done('error', null, '首页里没解析到原型');
        return;
      }
      const secs: ProtoSectionLink[] = home.links;
      Promise.all(secs.map((l: ProtoSectionLink): Promise<ProtoPage> =>
        ProtoCatalog.get(l.href, header).catch((): ProtoPage => ({ code: 0, body: '' } as ProtoPage))))
        .then((pages: ProtoPage[]) => {
          const extra: ProtoItem[] = [];
          for (let i = 0; i < pages.length; i++) {
            if (pages[i].code === 200) {
              ProtoCatalog.parseItems(pages[i].body, secs[i].section, extra);
            }
          }
          done('ok', ProtoCatalog.merge(home, extra), '');
        });
    }).catch((e: Object) => {
      done('error', null, '网络错误：' + JSON.stringify(e));
    });
  }

  private static get(path: string, header: Record<string, string>): Promise<ProtoPage> {
    const req = http.createHttp();
    return req.request(PROTO_ORIGIN + path, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 10000,
      readTimeout: 20000,
      expectDataType: http.HttpDataType.STRING,
    }).then((rsp: http.HttpResponse): ProtoPage => {
      req.destroy();
      return { code: rsp.responseCode, body: rsp.responseCode === 200 ? rsp.result as string : '' } as ProtoPage;
    }).catch((e: Object): ProtoPage => {
      req.destroy();
      throw new Error(JSON.stringify(e));
    });
  }

  /// 首页条目 + 分区页条目按网址合并：分区页的日期/描述优先，分区页独有的补进来
  private static merge(home: ProtoParsed, extra: ProtoItem[]): ProtoCache {
    const byUrl: Map<string, ProtoItem> = new Map();
    const order: string[] = [];
    const add = (it: ProtoItem, preferNew: boolean): void => {
      const k: string = it.url.replace(new RegExp('(index\\.html)?$'), '');
      const old: ProtoItem | undefined = byUrl.get(k);
      if (old === undefined) {
        byUrl.set(k, it);
        order.push(k);
      } else if (preferNew) {
        byUrl.set(k, {
          section: old.section, url: old.url,
          title: it.title.length > 0 ? it.title : old.title,
          desc: it.desc.length > 0 ? it.desc : old.desc,
          updated: it.updated > old.updated ? it.updated : old.updated,
        } as ProtoItem);
      }
    };
    home.items.forEach((it: ProtoItem) => add(it, false));
    extra.forEach((it: ProtoItem) => add(it, true));
    return {
      fetchedAt: Date.now(),
      sections: home.sections,
      items: order.map((k: string): ProtoItem => byUrl.get(k) as ProtoItem),
    } as ProtoCache;
  }

  static parse(html: string): ProtoParsed {
    const sections: string[] = [];
    const links: ProtoSectionLink[] = [];
    const items: ProtoItem[] = [];
    const secRe = new RegExp('<section class="group">([\\s\\S]*?)</section>', 'g');
    let sm: RegExpExecArray | null = secRe.exec(html);
    while (sm !== null) {
      const body: string = sm[1];
      const hm = body.match(new RegExp('<h2>([\\s\\S]*?)</h2>'));
      const section: string = hm !== null ? ProtoCatalog.text(hm[1]) : '';
      const n: number = ProtoCatalog.parseItems(body, section, items);
      if (section.length > 0 && n > 0) {
        sections.push(section);
        const to = body.match(new RegExp('class="to-section" href="([^"]+)"'));
        if (to !== null && to[1].startsWith('/')) {
          links.push({ section: section, href: to[1] } as ProtoSectionLink);
        }
      }
      sm = secRe.exec(html);
    }
    return { sections: sections, links: links, items: items } as ProtoParsed;
  }

  /// 抽 <a class="item">：标题在 h3（首页）或 h2（分区页）里，去掉 <span class="upd">
  static parseItems(html: string, section: string, out: ProtoItem[]): number {
    const itemRe = new RegExp('<a class="item"([^>]*)>([\\s\\S]*?)</a>', 'g');
    let im: RegExpExecArray | null = itemRe.exec(html);
    let n: number = 0;
    while (im !== null) {
      const attrs: string = im[1];
      const inner: string = im[2];
      const href = attrs.match(new RegExp('href="([^"]+)"'));
      if (href !== null && href[1] !== '/') {
        const upd = attrs.match(new RegExp('data-updated="([^"]*)"'));
        const h = inner.match(new RegExp('<h[23]>([\\s\\S]*?)</h[23]>'));
        const p = inner.match(new RegExp('<p>([\\s\\S]*?)</p>'));
        let title: string = h !== null
          ? ProtoCatalog.text(h[1].replace(new RegExp('<span class="upd">[^<]*</span>'), '')) : '';
        if (title.length === 0) {
          title = href[1];
        }
        out.push({
          section: section,
          url: href[1].startsWith('http') ? href[1] : PROTO_ORIGIN + href[1],
          title: title,
          desc: p !== null ? ProtoCatalog.text(p[1]) : '',
          updated: upd !== null ? upd[1] : '',
        } as ProtoItem);
        n++;
      }
      im = itemRe.exec(html);
    }
    return n;
  }

  private static text(s: string): string {
    return s.replace(new RegExp('<[^>]+>', 'g'), ' ')
      .replace(new RegExp('&amp;', 'g'), '&').replace(new RegExp('&lt;', 'g'), '<')
      .replace(new RegExp('&gt;', 'g'), '>').replace(new RegExp('&quot;', 'g'), '"')
      .replace(new RegExp('&#39;', 'g'), '\'').replace(new RegExp('&nbsp;', 'g'), ' ')
      .replace(new RegExp('\\s+', 'g'), ' ').trim();
  }
}
