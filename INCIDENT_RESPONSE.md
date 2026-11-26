# 🚨 In caso di attacco

Cosa fare, in ordine, quando BCM è attaccato o si sospetta che lo sia. Scritto
il 2026-11-26. In italiano di proposito: è il documento da seguire sotto
pressione. Il ripristino vero e proprio è in [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md);
qui c'è tutto quello che viene prima e dopo.

> **Regola d'oro: prima di cancellare o ricostruire, copia le prove.**
> E tieni un registro: ora, cosa hai visto, cosa hai fatto. Serve per capire,
> e per l'eventuale notifica al Garante.

```bash
# Collegarsi al server
ssh -i ~/.ssh/bcm_prod_key ubuntu@204.216.211.182
cd ~/bcm-v2/bcm-v2-docker
```

## 1. Come te ne accorgi

| Segnale | Da dove arriva |
|---|---|
| Sito giù o lentissimo | email di UptimeRobot |
| Backup o controlli notturni mancati | email di Healthchecks.io |
| "Account bloccato" a un utente | email automatica di BCM (troppi tentativi sbagliati) |
| "Nuovo accesso al tuo account" che l'utente non riconosce | email automatica di BCM (accesso da un tipo di dispositivo nuovo) |
| Molti eventi di sicurezza | resoconto settimanale; pagina Registro attività (admin) |
| File infetto caricato | log del backend (ClamAV) |
| Un cliente segnala dati strani, email che non ha mandato, accessi che non ha fatto | lui |

## 2. Primi 15 minuti: quanto è grave?

| Livello | Cosa succede | Cosa fai |
|---|---|---|
| **A. Tentativi** | scansioni, password sbagliate, traffico strano, nessuno è entrato | osserva, blocca gli indirizzi (§3.1), annota |
| **B. Un account preso** | qualcuno è entrato con la password di un utente | blocca quell'accesso (§3.2), avvisa l'utente, controlla cosa ha fatto |
| **C. Server o dati compromessi** | codice eseguito sul server, database letto o modificato, segreti esposti | metti offline (§3.3), copia le prove (§4), poi §5-§7 per intero |
| **D. Attacco di massa (DDoS)** | il sito non risponde per troppo traffico, nessuno è entrato | §3.4 |

Nel dubbio tra due livelli, scegli il più grave.

## 3. Fermare l'attacco

### 3.1 Bloccare un indirizzo IP

Ogni richiesta al sito finisce nel registro di Caddy (il server web),
`/var/log/caddy/access.log`: un file al giorno, cancellato dopo 14 giorni.

```bash
# Chi ha fatto più richieste nel registro di oggi
sudo grep -o '"remote_ip":"[^"]*"' /var/log/caddy/access.log | sort | uniq -c | sort -rn | head -20
# Le richieste di un indirizzo, le ultime 50
sudo grep '"remote_ip":"<IP>"' /var/log/caddy/access.log | tail -50
# Gli indirizzi collegati in questo momento
sudo ss -tn state established '( sport = :443 )' | awk 'NR>1{sub(/:[0-9]+$/,"",$4); print $4}' | sort | uniq -c | sort -rn | head -20
# Cosa vede il backend: accessi falliti, blocchi, rifiuti
docker compose logs --since 1h backend | grep -i -E "fail|denied|locked|refused|rate" | tail -50
```

```bash
# Blocca un indirizzo (vale fino al riavvio del server)
sudo iptables -I INPUT 1 -s <IP> -j DROP
# Toglie il blocco
sudo iptables -D INPUT -s <IP> -j DROP
```

### 3.2 Un account usato da qualcun altro

1. Da BCM, come admin, pagina Utenti: cambia la password dell'utente (Modifica → Password), o eliminalo; annota l'ora. Una password nuova chiude subito tutte le sessioni aperte di quell'utente. Se servisse chiudere le sessioni di **tutti**, §5 (chiave dei login).
2. Se è un admin: la 2FA è obbligatoria, quindi chi è entrato aveva anche il codice. Trattalo come **livello C**.
3. Guarda nel Registro attività cosa ha fatto quell'utente da quando è entrato.

### 3.3 Mettere il sito offline

```bash
sudo systemctl stop caddy      # il sito smette di rispondere; i dati restano
sudo systemctl start caddy     # lo rimette online
```

Il database e il backend continuano a girare: puoi copiare le prove e fare il backup.
Se il server stesso è compromesso, non riavviarlo e non cancellarlo: §4, poi una VM nuova.

### 3.4 Attacco di massa (DDoS)

Il server da solo non regge un attacco di massa. In emergenza si mette davanti
**Cloudflare, piano gratuito**:

1. crea l'account Cloudflare e aggiungi il dominio `donatocorbacio.dev`;
2. Cloudflare copia i record DNS da Porkbun: controlla che il record `A` di `bcm` punti a `204.216.211.182` con la nuvola **arancione** (proxy attivo);
3. su Porkbun, sostituisci i nameserver con i due indicati da Cloudflare;
4. su Cloudflare: Sicurezza → attiva "Under Attack Mode" finché l'attacco dura.

**Conseguenze da sistemare dopo:** il traffico passa da un'azienda americana,
quindi vanno aggiornate l'informativa privacy (oggi dice che il sito non passa
da Cloudflare) e le pagine che parlano dei dati in Italia. Finita l'emergenza,
si valuta se tornare indietro.

## 4. Copiare le prove

Prima di qualsiasi ripristino o rotazione:

```bash
D=~/incidente-$(date +%Y%m%d-%H%M); mkdir -p $D
docker compose logs --since 72h --timestamps > $D/container.log
sudo journalctl -u caddy --since "72 hours ago" -o cat > $D/caddy.log
sudo cp /var/log/caddy/access*.log* $D/      # il registro delle richieste, 14 giorni
sudo journalctl --since "72 hours ago" > $D/sistema.log
sudo last -a > $D/accessi-ssh.txt; sudo lastb -a 2>/dev/null | head -500 > $D/accessi-ssh-falliti.txt
docker ps -a > $D/container.txt; sudo ss -tlnp > $D/porte.txt
bash ops/backup/backup.sh       # una fotografia del database e dei file, com'è adesso
```

Poi copia la cartella sul tuo computer (`scp -r`), fuori dal server.

## 5. Cambiare i segreti

Al **livello C** si considerano letti tutti i segreti del server. L'elenco e gli
script sono in [DISASTER_RECOVERY.md, sezione 7](DISASTER_RECOVERY.md#7-if-the-old-vm-was-compromised):
chiave dei login (JWT), password MySQL, Redis, chiave della 2FA, chiavi interne,
chiave di firma del servizio ML, chiavi Stripe, password della posta.

Per far scadere **tutte** le sessioni aperte, la nuova chiave dei login va messa
**senza** tenere la vecchia come "precedente".

E fuori dal server:

- SSH: crea una chiave nuova e togli la vecchia da `~/.ssh/authorized_keys`;
- Oracle Cloud, Porkbun, GitHub, Stripe, Healthchecks.io, UptimeRobot: cambia le password e controlla che la 2FA sia attiva;
- alla fine, un nuovo pacchetto di recupero: `bash ops/secrets/recovery-bundle.sh`.

## 6. Ripristinare

| Situazione | Cosa fare |
|---|---|
| Server compromesso | VM nuova: [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) dall'inizio, poi la sezione 7 |
| Dati modificati o cancellati, server sano | ripristino del database dal backup **precedente** all'attacco (DISASTER_RECOVERY.md, sezione 4) |
| Solo tentativi (livello A) | niente da ripristinare |

## 7. Avvisare

Se sono coinvolti **dati personali** (nomi, email, contratti, IBAN...) è una
violazione di dati personali secondo il GDPR. **Il tempo conta dal momento in
cui te ne accorgi.**

- **Per i dati dei clienti** (i loro contratti, fornitori, fatture): BCM li tratta
  per conto loro (responsabile del trattamento). Va avvisato **ogni cliente
  coinvolto senza ritardo** (art. 33.2 GDPR): sono loro a decidere se notificare
  il Garante. Aiutali con le informazioni che hai.
- **Per i dati degli account** (utenti, email, accessi) e degli abbonamenti, di cui
  BCM è titolare: **notifica al Garante entro 72 ore** (art. 33), dal servizio
  online sul sito del Garante (garanteprivacy.it, "Notifica di una violazione
  dei dati personali"), a meno che sia improbabile un rischio per le persone.
  Se non hai ancora tutte le informazioni, notifica comunque e completa dopo.
- **Se il rischio per le persone è alto** (es. password, IBAN, documenti
  esposti): avvisa anche le persone coinvolte (art. 34).
- **Sempre**, anche se non notifichi: scrivi cosa è successo, i dati
  coinvolti, cosa hai fatto (art. 33.5). Questo file di registro va tenuto.
- Se c'è un reato (accesso abusivo, estorsione): denuncia alla Polizia Postale
  (commissariatodips.it).

Prima di avere clienti paganti, far rivedere questa sezione al legale.

### Modello di email ai clienti

> Oggetto: Avviso di sicurezza su BCM
>
> Gentile cliente, il [data] alle [ora] abbiamo rilevato [cosa è successo, in una frase].
> I dati coinvolti sono [quali]. Non risultano coinvolti [quali no].
> Abbiamo già [cosa hai fatto: bloccato, cambiato le chiavi, ripristinato].
> Per sicurezza ti chiediamo di [cambiare la password / verificare gli IBAN dei fornitori / ...].
> Ti scriveremo di nuovo entro [quando] con gli aggiornamenti.
> Per qualsiasi domanda: [contatto].

## 8. Dopo

1. Capire **da dove è entrato**: dai log copiati al §4.
2. Chiudere la falla, con un test che la riproduca.
3. Scrivere in `handoff/` una pagina: cosa è successo, quando, come, cosa è cambiato.
4. Rimettere online solo quando la falla è chiusa e i segreti sono nuovi.
