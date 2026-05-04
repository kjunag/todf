# todf — Tools of Digital Freedom

Infrastruktura self-hosted na AWS, zarządzana przez Terraform. Zawiera:

| Usługa | Subdomena | Opis |
|--------|-----------|------|
| **Authentik** | `auth.todf.mom` | Identity provider / SSO |
| **Nextcloud** | `cloud.todf.mom` | Przechowywanie plików |
| **Collabora** | `collabora.todf.mom` | Edytor dokumentów (online office dla Nextcloud) |
| **Stalwart** | `mail.todf.mom` | Serwer e-mail (SMTP/IMAP) |

Wspólna infrastruktura: VPC, ECS Fargate, RDS PostgreSQL, ElastiCache Redis, EFS, ALB, ACM, Route53.

---

## Wymagania

- Terraform >= 1.5
- AWS CLI skonfigurowane (`aws configure`) z uprawnieniami do tworzenia zasobów
- Zarejestrowana domena (domyślnie `todf.mom`) z możliwością ustawienia serwerów NS
- Konto na [resend.com](https://resend.com) (relay SMTP dla Authentik i Stalwart)

---

## Struktura

```
bootstrap/          # jednorazowe — tworzy S3 bucket i DynamoDB dla stanu Terraform
stages/
  01-dns/           # Route53 hosted zone
  02-infra/         # VPC, RDS, Redis, EFS, ECS cluster, Secrets Manager
  03-platform/      # ACM certificate, ALB
  04-authentik/     # Authentik na ECS
  05-nextcloud/     # Nextcloud + Collabora na ECS
  06-stalwart/      # Stalwart mail server na ECS
modules/            # moduły współdzielone przez stage'y
authentik_blueprints/  # blueprinty do importu w Authentik (flow logowania, zaproszenia)
backend_config.hcl  # generowany przez bootstrap — konfiguracja backendu S3
```

---

## Deployment

### Krok 0 — Bootstrap (jednorazowo)

Tworzy bucket S3 na stan Terraform i tabelę DynamoDB do lockowania. Uruchom raz przy pierwszym deploymencie.

```bash
cd bootstrap
terraform init
terraform apply
```

Bootstrap generuje plik `backend_config.hcl` w katalogu głównym — jest używany przez wszystkie kolejne stage'y.

---

### Krok 1 — DNS (`stages/01-dns`)

Tworzy hosted zone w Route53.

```bash
cd stages/01-dns
terraform init -backend-config="../../backend_config.hcl"
terraform apply
```

Po zakończeniu pobierz serwery NS i ustaw je w panelu rejestratora domeny:

```bash
terraform output name_servers
```

> Propagacja NS może zająć do 48 godzin. Kolejne kroki można zacząć wcześniej, ale walidacja certyfikatu (krok 3) wymaga aktywnej delegacji DNS.

---

### Krok 2 — Infrastruktura (`stages/02-infra`)

Tworzy sieć (VPC, podsieci, NAT), RDS PostgreSQL, ElastiCache Redis, EFS, klaster ECS oraz sekrety w Secrets Manager.

```bash
cd stages/02-infra
terraform init -backend-config="../../backend_config.hcl"
terraform apply
```

**Po zakończeniu — ustaw klucz API Resend:**

Stage tworzy sekret `todf/resend-smtp` z placeholderem hasła. Jest on używany zarówno przez Authentik (wysyłka e-maili), jak i przez Stalwart (relay SMTP). Przed deploymentem Authentik zastąp go prawdziwym kluczem API z resend.com:

```bash
aws secretsmanager put-secret-value \
  --secret-id todf/resend-smtp \
  --secret-string '{"username":"resend","password":"re_TWOJ_KLUCZ_API"}'
```

---

### Krok 3 — Platform (`stages/03-platform`)

Tworzy certyfikat ACM (wildcard `*.todf.mom`) i Application Load Balancer.

```bash
cd stages/03-platform
terraform init -backend-config="../../backend_config.hcl"
terraform apply
```

> Terraform automatycznie doda rekordy DNS do walidacji certyfikatu. Walidacja wymaga aktywnej delegacji NS z kroku 1.

---

### Krok 4 — Authentik (`stages/04-authentik`)

Deployuje Authentik (identity provider) na ECS Fargate.

```bash
cd stages/04-authentik
terraform init -backend-config="../../backend_config.hcl"
terraform apply
```

Domyślnie Authentik wysyła e-maile przez `smtp.resend.com:587` używając sekretu `todf/resend-smtp`. Nadawcą jest `noreply@todf.mom`. Wartości można zmienić przez zmienne Terraform (`email_host`, `email_port`, `email_username`, `email_from`).

Hasło bootstrapowe admina pobierz z Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id todf/authentik-bootstrap-password \
  --query SecretString --output text
```

Zaloguj się na `https://auth.todf.mom` i dokończ konfigurację.

#### Blueprinty

W katalogu `authentik_blueprints/` znajdują się gotowe blueprinty do zaimportowania w panelu Authentik (**Customisation → Blueprints → Import**):

| Plik | Co tworzy |
|------|-----------|
| `passwordless-authentication-flow.yaml` | Flow logowania przez WebAuthn (passkey) — **importuj jako pierwszy** |
| `default-authentication-flow.yaml` | Flow logowania hasłem + passkey (jako nowy flow `custom-authentication-flow`) |
| `flows-invitation-enrollment.yaml` | Trzy flow do rejestracji przez zaproszenie (zewnętrzni, wewnętrzni, engineering) |

---

### Krok 5 — Nextcloud + Collabora (`stages/05-nextcloud`)

Deployuje Nextcloud i Collabora na ECS Fargate. Stage automatycznie tworzy bazę danych `nextcloud` w RDS przez jednorazowy task ECS.

```bash
cd stages/05-nextcloud
terraform init -backend-config="../../backend_config.hcl"
terraform apply
```

Nextcloud dostępny pod `https://cloud.todf.mom`.

---

### Krok 6 — Stalwart (`stages/06-stalwart`)

Deployuje Stalwart Mail Server na ECS Fargate. Stage automatycznie tworzy bazę danych `stalwart` w RDS.

Ustaw hasło recovery przed apply (opcjonalne, ale zalecane):

```bash
cd stages/06-stalwart
terraform init -backend-config="../../backend_config.hcl"
terraform apply -var="stalwart_recovery_password=TWOJE_HASLO"
```

Zarządzanie mailem dostępne pod `https://mail.todf.mom`.

---

## Aktualizacja pojedynczego stage'a

Każdy stage można deployować niezależnie — wejdź do jego katalogu i wykonaj `terraform apply`. Zmiany w jednym stage nie wymagają ponownego apply pozostałych, chyba że zmieniły się outputy, na których się opierają.

## Niszczenie infrastruktury

Stage'y należy niszczyć w odwrotnej kolejności:

```bash
for stage in 06-stalwart 05-nextcloud 04-authentik 03-platform 02-infra 01-dns; do
  cd stages/$stage
  terraform destroy
  cd ../..
done
```

Na końcu usuń zasoby bootstrap:

```bash
cd bootstrap
terraform destroy
```

> Przed `terraform destroy` na bootstrap upewnij się, że bucket S3 jest pusty (usuń stany Terraform ze wszystkich stage'y).
