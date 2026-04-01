# Guía: Cómo enviar tu ERC de Coercion-Resistant Vault

## Contenido del paquete

- `ERC-XXXX.md` — Borrador completo del ERC siguiendo la plantilla de EIP-1
- `CoercionResistantVault.sol` — Implementación de referencia en Solidity 0.8.20
- `ROADMAP.md` — Este documento

---

## Fase 1: Pre-discusión (2-4 semanas)

### 1.1 Publicar en Ethereum Magicians

Ve a https://ethereum-magicians.org y crea un nuevo topic en la categoría "EIPs".

**Título sugerido:** `[ERC] Coercion-Resistant Vault Standard — Spending limits + timelock + multisig for anti-wrench-attack wallets`

**Estructura del post:**

```
## Problema
Los ataques físicos contra holders de criptomonedas aumentaron un 169% en 2025,
con más de 70 casos confirmados. Las wallets actuales permiten acceso inmediato
e irreversible al balance total, creando un incentivo perverso para la coerción.

## Solución propuesta
Un estándar de smart contract wallet con:
- Hot balance con límite de gasto por época (ej: 0.5 ETH/24h)
- Cold vault con timelock (ej: 72h) para fondos bloqueados
- Multisig opcional para desbloqueo acelerado por guardianes
- Cancelación de retiros pendientes por owner o guardianes
- Cambios de configuración también sujetos a timelock

## Analogía
Funciona como las cajas fuertes bancarias con apertura retardada:
incluso quien tiene las llaves no puede abrir la bóveda inmediatamente.

## Diferencias clave vs soluciones existentes
- vs Duress wallets: No requiere engañar al atacante; la limitación es
  verificable on-chain
- vs Multisig puro: Permite gasto diario sin fricción
- vs Timelock puro: No bloquea el uso cotidiano

## Borrador preliminar
[Link al ERC-XXXX.md]

## Implementación de referencia
[Link al CoercionResistantVault.sol]

## Feedback solicitado
- ¿El spending limit por época es el approach correcto vs un "hot pool" fijo?
- ¿Debería el estándar cubrir ERC-20 tokens en la interfaz base?
- ¿Sugerencias sobre thresholds por defecto recomendados?
```

### 1.2 Recoger feedback

Responde activamente a los comentarios. Los puntos que probablemente surgirán:

- **"¿Y si el atacante se queda 72 horas?"** — Respuesta: el límite de gasto por
  época limita la extracción incluso en periodos largos. Además, el timelock da
  tiempo a los guardianes para cancelar.

- **"¿No es esto simplemente un multisig?"** — Respuesta: la innovación es la
  combinación de rate-limiting + timelock + multisig como estándar interoperable,
  no un contrato ad-hoc.

- **"¿Compatibilidad con ERC-4337?"** — Respuesta: sí, el hotSpend() funciona
  como execute() de un smart account. Debería haber un módulo compatible.

- **"¿Esto debería ser un Core EIP?"** — Respuesta: no, es un ERC (estándar de
  aplicación). No requiere cambios al protocolo de consenso.

---

## Fase 2: Formalización (1-2 semanas)

### 2.1 Preparar el repositorio

```bash
# Clonar el repo de EIPs
git clone https://github.com/ethereum/EIPs.git
cd EIPs

# Crear una rama
git checkout -b erc-coercion-resistant-vault

# Copiar tu borrador
cp path/to/ERC-XXXX.md EIPS/eip-XXXX.md
mkdir -p assets/eip-XXXX
cp path/to/CoercionResistantVault.sol assets/eip-XXXX/
```

### 2.2 Ajustar el formato

El ERC-XXXX.md ya está en formato correcto. Verificar:

- [ ] Encabezado YAML ("preamble") con todos los campos requeridos
- [ ] `status: Draft`
- [ ] `type: Standards Track`
- [ ] `category: ERC`
- [ ] `requires: 165, 4337`
- [ ] Secciones obligatorias: Abstract, Motivation, Specification,
      Rationale, Backwards Compatibility, Security Considerations,
      Copyright
- [ ] La implementación de referencia está en `assets/eip-XXXX/`
- [ ] Las keywords RFC 2119 están en mayúsculas (MUST, SHOULD, etc.)
- [ ] Licencia CC0

### 2.3 Validar localmente

```bash
# Instalar el linter de EIPs
cargo install eipw
eipw --config ./config/eipw.toml EIPS/eip-XXXX.md

# Verificar markdown
npx markdownlint-cli2 EIPS/eip-XXXX.md
```

### 2.4 Abrir Pull Request

```bash
git add EIPS/eip-XXXX.md assets/eip-XXXX/
git commit -m "Add ERC-XXXX: Coercion-Resistant Vault Standard"
git push origin erc-coercion-resistant-vault
```

Abre PR en https://github.com/ethereum/EIPs/pulls

**Título del PR:** `Add ERC-XXXX: Coercion-Resistant Vault Standard`

**Descripción del PR:**
```
This ERC defines a standard for smart contract wallets that partition
funds into a rate-limited hot balance and a timelocked cold vault,
protecting against physical coercion attacks.

Discussion: [link a tu topic en Ethereum Magicians]
```

Un editor de EIPs revisará el formato y asignará un número oficial.

---

## Fase 3: Iterar y validar (2-6 meses)

### 3.1 Draft → Review

- Incorporar feedback de la comunidad y editores
- Solicitar revisión de seguridad del contrato
- Implementar tests completos (Foundry o Hardhat)
- Desarrollar un frontend de demostración (opcional pero recomendable)

### 3.2 Review → Last Call

- Presentar en un AllCoreDevs call (si se considera relevante)
- Obtener al menos una implementación alternativa
- Periodo de Last Call: mínimo 14 días de revisión pública

### 3.3 Last Call → Final

- Resolver cualquier issue técnico pendiente
- El ERC se convierte en estándar final

---

## Fase 4: Adopción (paralelo)

### Acciones recomendadas para impulsar la adopción:

1. **Auditoría de seguridad**: Contratar firma reconocida (Trail of Bits,
   OpenZeppelin, Consensys Diligence)

2. **Integración con wallets populares**:
   - Safe (anteriormente Gnosis Safe) — módulo compatible
   - MetaMask Snaps — extensión que implemente el estándar
   - Argent, Ambire — wallets con smart accounts

3. **Desplegar en testnets**: Sepolia, Holesky

4. **Herramientas de configuración**: Un frontend donde los usuarios
   puedan desplegar su vault sin escribir código

5. **Partnerships**: Hablar con proyectos de account abstraction (ERC-4337)
   y fabricantes de hardware wallets (Ledger, Trezor)

6. **Contenido**: Escribir artículos, hilos de Twitter/X, presentaciones
   en conferencias (ETHDenver, Devcon, ETHBarcelona)

---

## Recursos útiles

- EIP-1 (proceso): https://eips.ethereum.org/EIPS/eip-1
- Template de EIP: https://github.com/ethereum/EIPs/blob/master/eip-template.md
- Ethereum Magicians: https://ethereum-magicians.org
- Repositorio de EIPs: https://github.com/ethereum/EIPs
- ERC-4337 (Account Abstraction): https://eips.ethereum.org/EIPS/eip-4337
- Jameson Lopp's attack tracker: https://github.com/jlopp/physical-bitcoin-attacks

---

## Ejemplos de configuración recomendada

### Perfil conservador (holder a largo plazo)
- Spending limit: 0.1 ETH / 24h
- Timelock: 72 horas
- Multisig: 2-de-3 guardians (familiar + abogado + hardware en caja de seguridad)

### Perfil moderado (usuario activo)
- Spending limit: 1 ETH / 24h
- Timelock: 48 horas
- Multisig: 2-de-3 guardians

### Perfil de uso frecuente (trader)
- Spending limit: 5 ETH / 24h
- Timelock: 24 horas
- Multisig: 3-de-5 guardians
