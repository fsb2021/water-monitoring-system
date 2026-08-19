const { onValueUpdated } = require("firebase-functions/v2/database");
const admin = require("firebase-admin");

admin.initializeApp();

const limits = {
  ec: {
    label: "Conductivité",
    min: 0,
    max: 3000,
    unit: "µS/cm",
  },
  ph: {
    label: "pH",
    min: 7,
    max: 8.5,
    unit: "",
  },
  temp: {
    label: "Température",
    min: 15,
    max: 30,
    unit: "°C",
  },
  turbidite: {
    label: "Turbidité",
    min: 0,
    max: 10,
    unit: "NTU",
  },
};

exports.checkSensorValue = onValueUpdated(
  {
    ref: "/capteurs/{sensorKey}/value",
    region: "europe-west1",
  },
  async (event) => {
    const sensorKey = event.params.sensorKey;

    if (!limits[sensorKey]) {
      console.log("Capteur inconnu:", sensorKey);
      return;
    }

    const value = Number(event.data.after.val());

    if (Number.isNaN(value)) {
      console.log("Valeur invalide:", event.data.after.val());
      return;
    }

    const cfg = limits[sensorKey];

    const outNow = value < cfg.min || value > cfg.max;

    const stateRef = admin
      .database()
      .ref(`/systemState/${sensorKey}/wasOut`);

    const stateSnap = await stateRef.get();

    const wasOut = stateSnap.val() === true;

    if (outNow && !wasOut) {
      await stateRef.set(true);

      await sendToUsers({
        title: `⚠️ ${cfg.label} hors norme`,
        body: `Valeur : ${value.toFixed(2)} ${cfg.unit} | Norme : ${cfg.min} - ${cfg.max} ${cfg.unit}`,
        sensorKey,
        type: "sensor_alert",
      });

      console.log(`${sensorKey} hors norme: ${value}`);
    }

    if (!outNow && wasOut) {
      await stateRef.set(false);

      await sendToUsers({
        title: `✅ ${cfg.label} revenu à la normale`,
        body: `Valeur : ${value.toFixed(2)} ${cfg.unit}`,
        sensorKey,
        type: "sensor_normal",
      });

      console.log(`${sensorKey} revenu normal: ${value}`);
    }
  }
);

async function sendToUsers({ title, body, sensorKey, type }) {
  const usersSnap = await admin.database().ref("/users").get();

  if (!usersSnap.exists()) {
    console.log("Aucun utilisateur trouvé");
    return;
  }

  const messages = [];

  usersSnap.forEach((userSnap) => {
    const user = userSnap.val();

    if (!user.fcmToken) return;

    if (user.notifications && user.notifications.app === false) return;
    if (user.notifications && user.notifications.sensorAlerts === false) return;

    messages.push({
      token: user.fcmToken,
      notification: {
        title: title,
        body: body,
      },
      data: {
        type: type,
        sensorKey: sensorKey,
      },
      android: {
        priority: "high",
        notification: {
          sound: "default",
        },
      },
    });
  });

  if (messages.length === 0) {
    console.log("Aucun token FCM disponible");
    return;
  }

  const response = await admin.messaging().sendEach(messages);

  console.log("Notifications envoyées:", response.successCount);
  console.log("Notifications échouées:", response.failureCount);
}