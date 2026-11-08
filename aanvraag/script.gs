/**
 * BuildCalc Inmeten: Google Spreadsheet-koppeling.
 * Plak dit hele script in Extensies > Apps Script van een lege Google Spreadsheet.
 * Daarna: Implementeren > Nieuwe implementatie > Web-app, Uitvoeren als: Ik, Toegang: Iedereen.
 * De link die eindigt op /exec plak je in BuildCalc (Instellingen > Inmeetaanvragen).
 */
const SLEUTEL = 'PLAK_HIER_DE_SLEUTEL'; // zet BuildCalc er zelf in als je op "Kopieer script" tikt

const KOP_A = ['id', 'ingediend', 'adres', 'opdrachtgever', 'deadline', 'werkvoorbereider', 'email', 'status', 'ingemeten', 'token', 'door'];
const KOP_W = ['naam', 'email', 'token', 'toegevoegd'];

function blad(naam, kop) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let s = ss.getSheetByName(naam);
  if (!s) { s = ss.insertSheet(naam); s.appendRow(kop); s.setFrozenRows(1); s.getRange('A:Z').setNumberFormat('@'); }
  return s;
}
// Oudere spreadsheets missen soms een kolom (bijv. 'door'): die zetten we er dan achteraan bij.
function aanvragen() {
  const s = blad('Aanvragen', KOP_A), kop = s.getDataRange().getValues()[0].map(String);
  KOP_A.forEach((k, i) => { if (kop.indexOf(k) < 0) s.getRange(1, i + 1).setValue(k); });
  return s;
}
const werkvoorbereiders = () => blad('Werkvoorbereiders', KOP_W);
function rijen(s) {
  const v = s.getDataRange().getValues(), kop = v.shift();
  return v.map((r, i) => { const o = { _rij: i + 2 }; kop.forEach((k, j) => o[k] = r[j] instanceof Date ? Utilities.formatDate(r[j], 'Europe/Amsterdam', 'yyyy-MM-dd') : String(r[j])); return o; });
}
const uit = o => ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);

function doGet() { return uit({ ok: true, wat: 'BuildCalc inmeten' }); }

function doPost(e) {
  const lock = LockService.getScriptLock(); lock.waitLock(20000);
  try {
    const d = JSON.parse(e.postData.contents || '{}');
    // Werkvoorbereider (met zijn eigen token uit de link)
    if (d.actie === 'mijn' || d.actie === 'indienen') {
      const w = rijen(werkvoorbereiders()).find(x => x.token && x.token === d.token);
      if (!w) return uit({ fout: 'Deze link werkt niet (meer). Vraag de calculator om een nieuwe link.' });
      if (d.actie === 'mijn') {
        const items = rijen(aanvragen()).filter(r => r.token === w.token && r.status !== 'verwijderd')
          .map(r => ({ adres: r.adres, opdrachtgever: r.opdrachtgever, deadline: r.deadline, status: r.status }));
        return uit({ naam: w.naam, items });
      }
      const lijst = (d.adressen || []).map(a => String(a).trim()).filter(Boolean).slice(0, 500);
      if (!lijst.length) return uit({ fout: 'Geen adressen' });
      const nu = Utilities.formatDate(new Date(), 'Europe/Amsterdam', 'yyyy-MM-dd HH:mm');
      const s = aanvragen();
      s.getRange(s.getLastRow() + 1, 1, lijst.length, KOP_A.length).setValues(lijst.map(a =>
        [Utilities.getUuid().slice(0, 8), nu, a, String(d.opdrachtgever || ''), String(d.deadline || ''), w.naam, w.email, 'open', '', w.token, '']));
      return uit({ ok: true, aantal: lijst.length });
    }
    // Calculator (BuildCalc, met de sleutel)
    if (SLEUTEL === 'PLAK_' + 'HIER_DE_SLEUTEL' || d.sleutel !== SLEUTEL) return uit({ fout: 'Sleutel klopt niet. Kopieer het script opnieuw vanuit BuildCalc.' });
    if (d.actie === 'lijst') {
      return uit({ items: rijen(aanvragen()).filter(r => r.status !== 'verwijderd').map(r => ({
        id: r.id, adres: r.adres, opdrachtgever: r.opdrachtgever, deadline: r.deadline, wvb: r.werkvoorbereider, email: r.email, status: r.status, ingediend: r.ingediend, door: r.door || '' })) });
    }
    if (d.actie === 'pak') {
      const s = aanvragen(), r = rijen(s).find(x => x.id === String(d.id));
      if (!r) return uit({ fout: 'Adres niet gevonden' });
      if (d.door && r.door && r.door !== d.door) return uit({ fout: r.door + ' meet dit al in' });
      s.getRange(r._rij, KOP_A.indexOf('door') + 1).setValue(String(d.door || ''));
      return uit({ ok: true });
    }
    if (d.actie === 'status') {
      const s = aanvragen(), r = rijen(s).find(x => x.id === String(d.id));
      if (!r) return uit({ fout: 'Adres niet gevonden' });
      const kol = k => KOP_A.indexOf(k) + 1;
      s.getRange(r._rij, kol('status')).setValue(d.status);
      s.getRange(r._rij, kol('ingemeten')).setValue(d.status === 'ingemeten' ? Utilities.formatDate(new Date(), 'Europe/Amsterdam', 'yyyy-MM-dd HH:mm') : '');
      let mail = false;
      if (d.status === 'ingemeten' && r.email) {
        const voornaam = String(r.werkvoorbereider).split(' ')[0];
        MailApp.sendEmail(r.email, 'Ingemeten: ' + r.adres,
          `Hoi ${voornaam},\n\n${r.adres}${r.opdrachtgever ? ' (' + r.opdrachtgever + ')' : ''} is ingemeten. Het staat in TopCalc en de foto's en maten staan in de projectmap op de pc. Je kunt verder uitwerken.\n\nGroet,\n${d.van || ''}`,
          Object.assign({ name: d.van || 'Inmeten' }, /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(d.antw || '')) ? { replyTo: String(d.antw) } : {}));
        mail = true;
      }
      return uit({ ok: true, mail });
    }
    if (d.actie === 'wvbLijst') return uit({ items: rijen(werkvoorbereiders()).filter(w => w.token).map(w => ({ naam: w.naam, email: w.email, token: w.token })) });
    if (d.actie === 'wvbToevoegen') {
      const token = Utilities.getUuid().replace(/-/g, '').slice(0, 16);
      werkvoorbereiders().appendRow([String(d.naam || ''), String(d.email || ''), token, Utilities.formatDate(new Date(), 'Europe/Amsterdam', 'yyyy-MM-dd')]);
      return uit({ ok: true, token });
    }
    return uit({ fout: 'Onbekende actie' });
  } catch (err) {
    return uit({ fout: String(err && err.message || err) });
  } finally { lock.releaseLock(); }
}
